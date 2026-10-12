import Foundation
import os

/// Sends JPEG frames to the PC viewer over a WebSocket.
///
/// At most one frame is in flight. Frames offered while a send is pending are
/// dropped, so a slow link lowers the frame rate instead of building up latency.
final class FrameSender: Sendable {
  enum Status: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
  }

  private struct State {
    var task: URLSessionWebSocketTask?
    var connected = false
    var sending = false
    // Bumped on every connect/disconnect so callbacks from an old socket are ignored.
    var generation = 0
    var pendingText: [String] = []
    // HEVC frames depend on earlier ones, so they are queued rather than dropped
    // one by one; past the backlog limit everything waits for the next keyframe.
    var videoInFlight = 0
    var waitingForKeyframe = true
  }

  private static let maxVideoInFlight = 8

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let session = URLSession(configuration: .ephemeral)
  private let onStatus: @Sendable (Status) -> Void
  private let onFrameSent: @Sendable (Int) -> Void

  init(
    onStatus: @escaping @Sendable (Status) -> Void,
    onFrameSent: @escaping @Sendable (Int) -> Void
  ) {
    self.onStatus = onStatus
    self.onFrameSent = onFrameSent
  }

  /// Whether a frame offered now would be sent rather than dropped.
  /// Lets the caller skip JPEG encoding for frames that would be dropped anyway.
  var isReady: Bool {
    state.withLock { $0.connected && !$0.sending }
  }

  func connect(to url: URL, hello: String) {
    let task = session.webSocketTask(with: url)
    let (generation, previous) = state.withLock { s in
      let previous = s.task
      s = State(task: task, generation: s.generation + 1, pendingText: s.pendingText)
      return (s.generation, previous)
    }
    previous?.cancel(with: .goingAway, reason: nil)
    onStatus(.connecting)
    task.resume()

    // The first completed send proves the handshake succeeded.
    task.send(.string(hello)) { [weak self] error in
      guard let self else { return }
      if let error {
        self.fail(generation: generation, error: error)
        return
      }
      let backlog: [String]? = self.state.withLock { s in
        guard s.generation == generation else { return nil }
        s.connected = true
        defer { s.pendingText = [] }
        return s.pendingText
      }
      guard let backlog else { return }
      for text in backlog {
        task.send(.string(text)) { _ in }
      }
      self.onStatus(.connected)
    }
    receive(on: task, generation: generation)
  }

  func disconnect() {
    let task = state.withLock { s in
      let task = s.task
      s = State(generation: s.generation + 1, pendingText: s.pendingText)
      return task
    }
    guard let task else { return }
    task.cancel(with: .normalClosure, reason: nil)
    onStatus(.disconnected)
  }

  /// Sends one JPEG frame. Returns false if the frame was dropped.
  @discardableResult
  func send(jpeg: Data) -> Bool {
    let claim: (URLSessionWebSocketTask, Int)? = state.withLock { s in
      guard s.connected, !s.sending, let task = s.task else { return nil }
      s.sending = true
      return (task, s.generation)
    }
    guard let (task, generation) = claim else { return false }

    let size = jpeg.count
    task.send(.data(jpeg)) { [weak self] error in
      guard let self else { return }
      if let error {
        self.fail(generation: generation, error: error)
        return
      }
      let isCurrent = self.state.withLock { s in
        guard s.generation == generation else { return false }
        s.sending = false
        return true
      }
      if isCurrent { self.onFrameSent(size) }
    }
    return true
  }

  /// Sends one Annex B HEVC access unit. Returns false if it was skipped.
  @discardableResult
  func send(video: Data, isKeyframe: Bool) -> Bool {
    let claim: (URLSessionWebSocketTask, Int)? = state.withLock { s in
      guard s.connected, let task = s.task else { return nil }
      if s.videoInFlight >= Self.maxVideoInFlight { s.waitingForKeyframe = true }
      if s.waitingForKeyframe {
        guard isKeyframe, s.videoInFlight < Self.maxVideoInFlight else { return nil }
        s.waitingForKeyframe = false
      }
      s.videoInFlight += 1
      return (task, s.generation)
    }
    guard let (task, generation) = claim else { return false }

    let size = video.count
    task.send(.data(video)) { [weak self] error in
      guard let self else { return }
      if let error {
        self.fail(generation: generation, error: error)
        return
      }
      let isCurrent = self.state.withLock { s in
        guard s.generation == generation else { return false }
        s.videoInFlight -= 1
        return true
      }
      if isCurrent { self.onFrameSent(size) }
    }
    return true
  }

  /// Best-effort text message (logs, status) to the viewer. Messages sent while
  /// not connected are kept (up to 100) and flushed after the next handshake.
  func send(text: String) {
    let task: URLSessionWebSocketTask? = state.withLock { s in
      if s.connected { return s.task }
      s.pendingText.append(text)
      if s.pendingText.count > 100 { s.pendingText.removeFirst(s.pendingText.count - 100) }
      return nil
    }
    task?.send(.string(text)) { _ in }
  }

  /// Keeps a receive pending so a closed or broken socket is noticed even while idle.
  /// Messages from the viewer are currently ignored.
  private func receive(on task: URLSessionWebSocketTask, generation: Int) {
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.receive(on: task, generation: generation)
      case .failure(let error):
        self.fail(generation: generation, error: error)
      }
    }
  }

  private func fail(generation: Int, error: any Error) {
    let (isCurrent, task) = state.withLock { s -> (Bool, URLSessionWebSocketTask?) in
      guard s.generation == generation else { return (false, nil) }
      let task = s.task
      s = State(generation: s.generation + 1, pendingText: s.pendingText)
      return (true, task)
    }
    guard isCurrent else { return }
    task?.cancel(with: .goingAway, reason: nil)
    onStatus(.failed(error.localizedDescription))
  }
}
