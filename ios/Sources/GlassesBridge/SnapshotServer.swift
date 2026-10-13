import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Network
import os

/// The newest glasses frame, kept so it can be served on request. JPEG
/// encoding happens only when someone asks, not for every frame.
final class LatestFrame: Sendable {
  /// Same size the PC relay serves: plenty for Muse, small enough for the Core2.
  static let maxSide: CGFloat = 640
  /// Older frames mean the stream stopped; they'd describe the past.
  static let maxAge: TimeInterval = 5

  private struct State {
    var image: CIImage?
    var time = Date.distantPast
  }

  private let state = OSAllocatedUnfairLock(uncheckedState: State())
  private let context = CIContext()

  func update(_ pixelBuffer: CVPixelBuffer) {
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    state.withLockUnchecked { $0 = State(image: image, time: Date()) }
  }

  func update(_ cgImage: CGImage) {
    let image = CIImage(cgImage: cgImage)
    state.withLockUnchecked { $0 = State(image: image, time: Date()) }
  }

  func clear() {
    state.withLockUnchecked { $0 = State() }
  }

  /// The latest frame as a JPEG, or nil if there is no recent one.
  func jpeg(quality: CGFloat = 0.7) -> Data? {
    let (image, time) = state.withLockUnchecked { ($0.image, $0.time) }
    guard let image, Date().timeIntervalSince(time) <= Self.maxAge else { return nil }
    let extent = image.extent
    let scale = min(1, Self.maxSide / max(extent.width, extent.height))
    let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
    return context.jpegRepresentation(
      of: scaled,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
    )
  }
}

/// Serves the latest glasses frame on the local network, so the Core2 can
/// fetch it without a PC: `GET /snapshot.jpg` returns one JPEG, or 503 while
/// the glasses aren't streaming. Advertised over Bonjour as
/// `_glasses-bridge._tcp`, which is how the Core2 finds the phone.
final class SnapshotServer: Sendable {
  static let serviceType = "_glasses-bridge._tcp"
  static let port: NWEndpoint.Port = 8765

  enum Status: Sendable, Equatable {
    case stopped
    case listening(UInt16)
    case failed(String)
  }

  private let frame: LatestFrame
  private let queue = DispatchQueue(label: "SnapshotServer")
  private let listener = OSAllocatedUnfairLock<NWListener?>(uncheckedState: nil)
  private let onStatus: @Sendable (Status) -> Void
  private let onRequest: @Sendable (_ served: Bool, _ from: String) -> Void

  init(
    frame: LatestFrame,
    onStatus: @escaping @Sendable (Status) -> Void,
    onRequest: @escaping @Sendable (_ served: Bool, _ from: String) -> Void
  ) {
    self.frame = frame
    self.onStatus = onStatus
    self.onRequest = onRequest
  }

  func start(name: String) {
    stop()
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = false
    let created: NWListener
    do {
      created = try NWListener(using: parameters, on: Self.port)
    } catch {
      onStatus(.failed(error.localizedDescription))
      return
    }
    created.service = NWListener.Service(name: name, type: Self.serviceType)
    created.stateUpdateHandler = { [weak self, weak created] state in
      // A replaced listener's last updates (its cancellation) aren't news.
      guard let self, let created, self.listener.withLockUnchecked({ $0 === created }) else { return }
      switch state {
      case .ready:
        self.onStatus(.listening(created.port?.rawValue ?? Self.port.rawValue))
      case .failed(let error):
        self.onStatus(.failed(error.localizedDescription))
      case .cancelled:
        self.onStatus(.stopped)
      default:
        break
      }
    }
    created.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.withLockUnchecked { $0 = created }
    created.start(queue: queue)
  }

  var isListening: Bool {
    listener.withLockUnchecked { $0?.state == .ready }
  }

  func stop() {
    let old = listener.withLockUnchecked { l in
      defer { l = nil }
      return l
    }
    old?.cancel()
  }

  // MARK: HTTP

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    // A client that never finishes its request doesn't hold the connection open.
    queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
    receive(on: connection, buffered: Data())
  }

  private func receive(on connection: NWConnection, buffered: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var request = buffered
      if let data { request.append(data) }
      if let end = request.range(of: Data("\r\n\r\n".utf8)) {
        self.respond(to: request[..<end.lowerBound], on: connection)
      } else if error != nil || isComplete || request.count > 8192 {
        connection.cancel()
      } else {
        self.receive(on: connection, buffered: request)
      }
    }
  }

  private func respond(to head: Data, on connection: NWConnection) {
    let requestLine = String(decoding: head.prefix { $0 != 0x0D }, as: UTF8.self)
    let parts = requestLine.split(separator: " ")
    let path = parts.count >= 2 ? parts[1].split(separator: "?").first.map(String.init) ?? "" : ""
    let from = Self.describe(connection.endpoint)

    let response: Data
    if parts.first != "GET" {
      response = Self.reply(status: "405 Method Not Allowed", type: "text/plain", body: Data("GET only\n".utf8))
    } else if path == "/snapshot.jpg" {
      if let jpeg = frame.jpeg() {
        response = Self.reply(status: "200 OK", type: "image/jpeg", body: jpeg)
        onRequest(true, from)
      } else {
        response = Self.reply(
          status: "503 Service Unavailable", type: "text/plain", body: Data("no recent frame\n".utf8))
        onRequest(false, from)
      }
    } else if path == "/" {
      response = Self.reply(
        status: "200 OK", type: "text/plain", body: Data("Glasses Bridge: GET /snapshot.jpg\n".utf8))
    } else {
      response = Self.reply(status: "404 Not Found", type: "text/plain", body: Data("not found\n".utf8))
    }
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }

  private static func reply(status: String, type: String, body: Data) -> Data {
    var out = Data(
      ("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        + "Cache-Control: no-store\r\nConnection: close\r\n\r\n").utf8)
    out.append(body)
    return out
  }

  private static func describe(_ endpoint: NWEndpoint) -> String {
    if case .hostPort(let host, _) = endpoint {
      return "\(host)"
    }
    return "\(endpoint)"
  }
}
