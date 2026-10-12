import MWDATCamera
import MWDATCore
import SwiftUI

struct ContentView: View {
  @Bindable var model: BridgeModel

  var body: some View {
    NavigationStack {
      Form {
        if let error = model.lastError {
          problemSection(error)
        }
        glassesSection
        streamSection
        statusSection
        if let preview = model.preview {
          Section("Preview") {
            Image(uiImage: preview)
              .resizable()
              .scaledToFit()
              .frame(maxHeight: 360)
          }
        }
        logSection
      }
      .navigationTitle("Glasses Bridge")
    }
  }

  private func problemSection(_ error: String) -> some View {
    Section("Problem") {
      Text(error)
        .foregroundStyle(.red)
      if model.needsGlassesAppUpdate {
        Button("Update glasses app in Meta AI") { model.openGlassesAppUpdate() }
        Button("Check glasses firmware in Meta AI") { model.openFirmwareUpdate() }
      }
    }
  }

  private var glassesSection: some View {
    Section("Glasses") {
      LabeledContent("Registration", value: model.registration.description)
      LabeledContent("Glasses", value: model.hasActiveDevice ? "connected" : "not connected")
      LabeledContent("Details", value: model.deviceInfo)
      if model.registration == .registered {
        Button("Unregister", role: .destructive) { model.unregister() }
          .disabled(model.isRunning)
      } else {
        Button("Register with Meta AI") { model.register() }
          .disabled(model.registration == .registering)
      }
    }
  }

  private var streamSection: some View {
    Section {
      TextField("PC address (host:port)", text: $model.host)
        .keyboardType(.numbersAndPunctuation)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .disabled(model.isRunning)
      Picker("Resolution", selection: $model.resolution) {
        ForEach(StreamingResolution.allCases, id: \.self) { resolution in
          Text(BridgeModel.label(for: resolution)).tag(resolution)
        }
      }
      .disabled(model.isRunning)
      Picker("Frame rate", selection: $model.frameRate) {
        ForEach(BridgeModel.frameRates, id: \.self) { fps in
          Text("\(fps) fps").tag(fps)
        }
      }
      .disabled(model.isRunning)
      Toggle("Keep streaming when phone is locked", isOn: $model.keepStreamingWhenLocked)
        .disabled(model.isRunning)
      if !model.keepStreamingWhenLocked {
        VStack(alignment: .leading) {
          Text("JPEG quality \(Int(model.jpegQuality * 100))%")
          Slider(value: $model.jpegQuality, in: 0.3...0.95)
        }
        .disabled(model.isRunning)
      }
      if model.isRunning {
        Button("Stop", role: .destructive) { model.stop() }
      } else {
        Button("Start streaming") { model.start() }
          .disabled(model.registration != .registered)
      }
    } header: {
      Text("Stream to computer")
    } footer: {
      Text("Run the viewer on the PC first. Settings apply on the next Start.")
    }
  }

  private var statusSection: some View {
    Section("Status") {
      LabeledContent("Session", value: model.sessionState.description)
      LabeledContent("Camera", value: BridgeModel.label(for: model.streamState))
      LabeledContent("PC link", value: linkText)
      LabeledContent("Frames", value: "\(model.fpsIn) in / \(model.fpsOut) out per s")
      LabeledContent("Upload", value: "\(model.kilobytesPerSecond) KB/s")
    }
  }

  private var logSection: some View {
    Section("Log") {
      ForEach(Array(model.log.enumerated().reversed()), id: \.offset) { _, line in
        Text(line)
          .font(.caption.monospaced())
      }
    }
  }

  private var linkText: String {
    switch model.link {
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .connected: "connected"
    case .failed(let reason): "failed: \(reason)"
    }
  }
}
