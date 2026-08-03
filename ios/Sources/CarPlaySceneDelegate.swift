import CarPlay
import UIKit

/// The OS entry point for the CarPlay scene. Thin: it hands the interface
/// controller to CarPlayController and tears down on disconnect.
///
/// This ships DORMANT: without the `com.apple.developer.carplay-voice-based-
/// conversation` entitlement (granted by Apple, then carried by the CI signing
/// profile) iOS never connects a CarPlay scene, so none of this runs and the
/// phone/iPad/Mac app is entirely unaffected. The code is inert until enabled —
/// not #if-gated — so `main` stays green throughout.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        let c = CarPlayController(interfaceController: interfaceController)
        controller = c
        c.start()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller?.stop()   // deactivates the audio session per Apple's category rule
        controller = nil
    }
}
