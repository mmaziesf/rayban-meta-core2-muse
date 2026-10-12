import MWDATCore
import SwiftUI

@main
struct GlassesBridgeApp: App {
  @State private var model: BridgeModel

  init() {
    var startupError: String?
    do throws(WearablesError) {
      try Wearables.configure()
    } catch {
      startupError = "Wearables.configure failed: \(error.description)"
    }
    _model = State(wrappedValue: BridgeModel(wearables: Wearables.shared, startupError: startupError))
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .onOpenURL { url in model.handleCallback(url) }
    }
  }
}
