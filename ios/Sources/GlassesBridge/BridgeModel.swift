import Foundation
import MWDATCamera
import MWDATCore
import Observation
import UIKit
import os

/// Glasses camera → JPEG → WebSocket → PC.
///
/// Flow: register with Meta AI once, then Start creates a DeviceSession, waits for
/// `.started`, checks camera permission, attaches a Camera and forwards every frame
/// the link can take to the PC viewer.
@Observable
@MainActor
final class BridgeModel {
  static let frameRates: [UInt] = [2, 7, 15, 24, 30]

  // Glasses
  private(set) var registration: RegistrationState = .unavailable
  private(set) var hasActiveDevice = false
  private(set) var deviceInfo = "—"
  private(set) var sessionState: DeviceSessionState = .idle
  private(set) var streamState: StreamState = .stopped

  // PC link
  private(set) var link: FrameSender.Status = .disconnected
  private(set) var isRunning = false

  // Last failure, kept after teardown so it stays visible.
  private(set) var lastError: String?
  private(set) var needsGlassesAppUpdate = false

  // Settings, applied on the next Start
  var host: String
  var resolution: StreamingResolution = .medium
  var frameRate: UInt = 15
  var jpegQuality = 0.6
  /// HEVC keeps flowing while the phone is locked; raw frames pause in the background.
  var keepStreamingWhenLocked = true

  // Stats, refreshed once per second
  private(set) var preview: UIImage?
  private(set) var fpsIn = 0
  private(set) var fpsOut = 0
  private(set) var kilobytesPerSecond = 0
  private(set) var log: [String] = []

  @ObservationIgnored private let wearables: any WearablesInterface
  @ObservationIgnored private let selector: AutoDeviceSelector
  @ObservationIgnored private var sender: FrameSender?
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private let sessionTokens = ListenerTokenBag()
  @ObservationIgnored private let streamTokens = ListenerTokenBag()
  @ObservationIgnored private let deviceTokens = ListenerTokenBag()
  @ObservationIgnored private var framesIn = 0
  @ObservationIgnored private var framesOut = 0
  @ObservationIgnored private var bytesOut = 0
  @ObservationIgnored private let previewDecoder = PreviewDecoder()
  @ObservationIgnored private let inForeground = OSAllocatedUnfairLock(initialState: true)

  init(wearables: any WearablesInterface, startupError: String?) {
    self.wearables = wearables
    self.selector = AutoDeviceSelector(wearables: wearables)
    self.host = UserDefaults.standard.string(forKey: "host") ?? ""
    self.sender = FrameSender(
      onStatus: { [weak self] status in
        Task { @MainActor in self?.linkChanged(status) }
      },
      onFrameSent: { [weak self] bytes in
        Task { @MainActor in self?.frameSent(bytes: bytes) }
      }
    )
    if let startupError { note(startupError) }

    Task { [weak self, wearables] in
      for await state in wearables.registrationStateStream() {
        self?.registration = state
        self?.note("registration: \(state.description)")
      }
    }
    Task { [weak self, selector] in
      for await device in selector.activeDeviceStream() {
        self?.hasActiveDevice = device != nil
        self?.watchDevice(device)
      }
    }
    Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
        self?.appVisibilityChanged(visible: false)
      }
    }
    Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
        self?.appVisibilityChanged(visible: true)
      }
    }
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        self?.rollStats()
      }
    }
  }

  // MARK: Diagnostics

  /// Logs the active glasses' type, link and SDK compatibility, and any later changes.
  private func watchDevice(_ id: DeviceIdentifier?) {
    deviceTokens.clear()
    guard let id else {
      deviceInfo = "—"
      note("glasses: none active")
      return
    }
    guard let device = wearables.deviceForIdentifier(id) else {
      note("glasses: active (\(id)) but no device details")
      return
    }
    deviceInfo = "\(device.deviceType().rawValue), link \(device.linkState), \(device.compatibility())"
    note("glasses: \(device.nameOrId()) \(deviceInfo)")
    device.addLinkStateListener { [weak self] state in
      Task { @MainActor in
        self?.note("glasses link: \(state)")
        self?.watchDeviceDetailsChanged(id)
      }
    }.store(in: deviceTokens)
    device.addCompatibilityListener { [weak self] compatibility in
      Task { @MainActor in
        self?.note("glasses compatibility: \(compatibility)")
        self?.watchDeviceDetailsChanged(id)
      }
    }.store(in: deviceTokens)
  }

  private func watchDeviceDetailsChanged(_ id: DeviceIdentifier) {
    guard let device = wearables.deviceForIdentifier(id) else { return }
    deviceInfo = "\(device.deviceType().rawValue), link \(device.linkState), \(device.compatibility())"
  }

  // MARK: Registration

  func register() {
    Task {
      do {
        try await wearables.startRegistration()
      } catch {
        note("registration failed: \(error.localizedDescription)")
      }
    }
  }

  func unregister() {
    Task {
      do {
        try await wearables.startUnregistration()
      } catch {
        note("unregistration failed: \(error.localizedDescription)")
      }
    }
  }

  /// Opens Meta AI's page for updating the DAT app on the glasses.
  func openGlassesAppUpdate() {
    Task {
      do {
        try await wearables.openDATGlassesAppUpdate()
      } catch {
        fail("could not open Meta AI: \(error.localizedDescription)")
      }
    }
  }

  func openFirmwareUpdate() {
    Task {
      do {
        try await wearables.openFirmwareUpdate()
      } catch {
        fail("could not open Meta AI: \(error.localizedDescription)")
      }
    }
  }

  /// Meta AI returns to the app via `glassesbridge://…?metaWearablesAction=…`.
  func handleCallback(_ url: URL) {
    guard
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      items.contains(where: { $0.name == "metaWearablesAction" })
    else { return }
    Task {
      do {
        _ = try await wearables.handleUrl(url)
      } catch {
        note("Meta AI callback failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: Streaming

  func start() {
    guard !isRunning else { return }
    let address = host.trimmingCharacters(in: .whitespaces)
    guard let url = URL(string: "ws://\(address)/ingest"), url.host != nil else {
      fail("invalid PC address '\(address)'; expected host:port")
      return
    }
    UserDefaults.standard.set(address, forKey: "host")
    isRunning = true
    preview = nil
    lastError = nil
    needsGlassesAppUpdate = false
    sender?.connect(to: url, hello: encode(Hello(
      device: UIDevice.current.name,
      resolution: Self.label(for: resolution),
      fps: frameRate,
      codec: keepStreamingWhenLocked ? "hevc" : "jpeg"
    )))
    note("connecting to \(url.absoluteString)")
    watchDevice(selector.activeDevice)

    do throws(DeviceSessionError) {
      let session = try wearables.createSession(deviceSelector: selector)
      self.session = session
      session.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.sessionChanged(state) }
      }.store(in: sessionTokens)
      session.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.sessionFailed(error) }
      }.store(in: sessionTokens)
      try session.start()
    } catch {
      sessionFailed(error)
      teardown()
    }
  }

  func stop() {
    camera?.stop()
    session?.stop()
    teardown()
  }

  private func sessionChanged(_ state: DeviceSessionState) {
    sessionState = state
    note("session: \(state.description)")
    switch state {
    case .started:
      if camera == nil { Task { await startCamera() } }
    case .stopped:
      teardown()
    default:
      break
    }
  }

  private func startCamera() async {
    guard let session, session.state == .started, camera == nil else { return }
    do {
      if try await wearables.checkPermissionStatus(.camera) != .granted {
        note("asking for camera permission in Meta AI")
        guard try await wearables.requestPermission(.camera) == .granted else {
          fail("camera permission denied")
          return
        }
      }
    } catch {
      fail("camera permission check failed: \(error.localizedDescription)")
      return
    }
    // Stop may have been pressed while Meta AI was in front.
    guard self.session === session, session.state == .started, camera == nil else { return }

    let codec: VideoCodec = keepStreamingWhenLocked ? .hvc1 : .raw
    let config = StreamConfiguration(videoCodec: codec, resolution: resolution, frameRate: frameRate)
    do throws(DeviceSessionError) {
      guard let camera = try session.addCamera(config: config) else {
        fail("glasses did not provide a camera")
        return
      }
      self.camera = camera
      observe(camera.stream)
      camera.stream.start()
    } catch {
      fail("could not add camera: \(error.description)")
    }
  }

  private func observe(_ stream: MWDATCamera.Stream) {
    guard let sender else { return }
    let quality = CGFloat(jpegQuality)

    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.streamChanged(state) }
    }.store(in: streamTokens)
    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.fail("stream error: \(error.description)") }
    }.store(in: streamTokens)
    if stream.streamConfiguration.videoCodec == .hvc1 {
      // Compressed frames go to the PC as-is; the preview is decoded only while visible.
      let decoder = previewDecoder
      let inForeground = inForeground
      let frameCount = OSAllocatedUnfairLock(initialState: 0)
      stream.videoFramePublisher.listen { [weak self] frame in
        guard let packet = HEVCPacketizer.annexB(from: frame.sampleBuffer) else { return }
        sender.send(video: packet.data, isKeyframe: packet.isKeyframe)
        var preview: UIImage?
        if inForeground.withLock({ $0 }) {
          let count = frameCount.withLock { n in
            n += 1
            return n
          }
          preview = decoder.decode(frame.sampleBuffer, isKeyframe: packet.isKeyframe, wantImage: count % 3 == 0)
        }
        Task { @MainActor in self?.frameReceived(preview) }
      }.store(in: streamTokens)
      return
    }
    stream.videoFramePublisher.listen { [weak self] frame in
      // Off the main actor: encode only when the link can take the frame.
      guard let image = frame.makeUIImage() else { return }
      if sender.isReady, let jpeg = image.jpegData(compressionQuality: quality) {
        sender.send(jpeg: jpeg)
      }
      Task { @MainActor in self?.frameReceived(image) }
    }.store(in: streamTokens)
  }

  private func streamChanged(_ state: StreamState) {
    streamState = state
    note("stream: \(Self.label(for: state))")
    if state == .stopped, camera != nil {
      streamTokens.clear()
      camera = nil
    }
  }

  private func teardown() {
    streamTokens.clear()
    sessionTokens.clear()
    camera = nil
    session = nil
    sessionState = .idle
    streamState = .stopped
    sender?.disconnect()
    isRunning = false
  }

  // MARK: Link and stats

  private func sessionFailed(_ error: DeviceSessionError) {
    if error == .datAppOnTheGlassesUpdateRequired {
      needsGlassesAppUpdate = true
    }
    fail("glasses: \(error.description) [\(String(describing: error))]")
  }

  private func fail(_ message: String) {
    lastError = message
    note(message)
  }

  private func linkChanged(_ status: FrameSender.Status) {
    link = status
    switch status {
    case .connected: note("PC connected")
    case .failed(let reason): fail("PC link failed: \(reason)")
    case .connecting, .disconnected: break
    }
  }

  private func frameReceived(_ image: UIImage?) {
    framesIn += 1
    if let image { preview = image }
  }

  private func appVisibilityChanged(visible: Bool) {
    inForeground.withLock { $0 = visible }
    if !visible { previewDecoder.reset() }
    guard isRunning else { return }
    if keepStreamingWhenLocked {
      note(visible ? "app visible" : "app in background: HEVC stream continues")
    } else {
      note(visible ? "app visible" : "app in background: raw stream pauses until you return")
    }
  }

  private func frameSent(bytes: Int) {
    framesOut += 1
    bytesOut += bytes
  }

  private func rollStats() {
    fpsIn = framesIn
    fpsOut = framesOut
    kilobytesPerSecond = bytesOut / 1024
    framesIn = 0
    framesOut = 0
    bytesOut = 0
  }

  /// Keeps the last 50 lines on screen and mirrors each one to the PC viewer,
  /// since there is no Xcode console when building with xtool.
  private func note(_ message: String) {
    let line = "\(Self.clock.string(from: Date())) \(message)"
    log.append(line)
    if log.count > 50 { log.removeFirst(log.count - 50) }
    NSLog("[GlassesBridge] %@", message)
    sender?.send(text: encode(LogLine(message: message)))
  }

  // MARK: Wire format and labels

  private struct Hello: Encodable {
    let type = "hello"
    let device: String
    let resolution: String
    let fps: UInt
    let codec: String
  }

  private struct LogLine: Encodable {
    let type = "log"
    let message: String
  }

  private func encode(_ value: some Encodable) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private static let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  static func label(for resolution: StreamingResolution) -> String {
    switch resolution {
    case .high: "high 720×1280"
    case .medium: "medium 504×896"
    case .low: "low 360×640"
    @unknown default: "unknown"
    }
  }

  static func label(for state: StreamState) -> String {
    switch state {
    case .stopping: "stopping"
    case .stopped: "stopped"
    case .waitingForDevice: "waiting for glasses"
    case .starting: "starting"
    case .streaming: "streaming"
    case .paused: "paused"
    }
  }
}
