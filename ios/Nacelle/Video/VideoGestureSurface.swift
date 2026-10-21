import SwiftUI
import UIKit

/// La surface de gestes posée sur la vidéo : un seul `UIView` transparent qui range les doigts entre le zoom et le tap.
///
/// Pourquoi UIKit : SwiftUI n'a pas de glissement « à deux doigts exactement » (`DragGesture` part dès un doigt, et se
/// disputerait le toucher avec le tap du mode épuré), ni de moyen simple de dire qu'un tap simple attend l'échec d'un
/// double tap. Ici :
/// - pincement et glissement à deux doigts (exactement deux) se reconnaissent ensemble, donc on zoome et on déplace d'un
///   même mouvement ;
/// - le double tap revient à l'image entière ;
/// - le tap simple (masquer ou rendre l'interface) attend que le double tap échoue, donc un double tap ne le déclenche pas.
/// Le joystick, le curseur de zoom et les boutons sont des vues SwiftUI posées au-dessus : un toucher qui commence sur eux
/// n'arrive jamais ici, et leurs gestes à un doigt ne sont pas ceux d'ici.
struct VideoGestureSurface: UIViewRepresentable {
    /// L'étiquette VoiceOver : ce que fait l'activation (le tap du mode épuré).
    var label: String
    /// L'image est agrandie : VoiceOver propose « Revenir à l'image entière » et lit le facteur.
    var zoomValue: String?
    var onTap: @MainActor () -> Void
    var onDoubleTap: @MainActor () -> Void
    /// Rapport du pas de pincement, point de contact (centre des doigts) et taille de la vue.
    var onPinch: @MainActor (_ factor: CGFloat, _ anchor: CGPoint, _ viewSize: CGSize) -> Void
    /// Déplacement des doigts depuis l'appel précédent, et taille de la vue.
    var onPan: @MainActor (_ translation: CGSize, _ viewSize: CGSize) -> Void
    /// Un geste de zoom commence (vrai) ou finit (faux, y compris annulé par le système).
    var onZoomGesture: @MainActor (_ active: Bool) -> Void

    static let resetActionName = "Revenir à l'image entière"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        let coordinator = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        // Deux doigts exactement : un doigt seul n'est jamais un glissement de zoom.
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        singleTap.require(toFail: doubleTap)

        for recognizer in [pinch, pan, doubleTap, singleTap] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        coordinator.pinch = pinch
        coordinator.pan = pan

        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        view.onActivate = { [coordinator] in coordinator.parent.onTap() }
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityLabel = label
        view.accessibilityValue = zoomValue
        view.accessibilityCustomActions = zoomValue == nil ? nil : [
            UIAccessibilityCustomAction(name: Self.resetActionName) { [coordinator = context.coordinator] _ in
                MainActor.assumeIsolated { coordinator.parent.onDoubleTap() }
                return true
            },
        ]
    }

    /// La vue : transparente, et activable par VoiceOver comme un tap.
    final class SurfaceView: UIView {
        var onActivate: (@MainActor () -> Void)?

        override func accessibilityActivate() -> Bool {
            onActivate?()
            return true
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: VideoGestureSurface
        weak var pinch: UIPinchGestureRecognizer?
        weak var pan: UIPanGestureRecognizer?

        init(_ parent: VideoGestureSurface) {
            self.parent = parent
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed:
                // Par petits pas : le facteur depuis le dernier appel, au centre actuel des doigts.
                let factor = recognizer.scale
                recognizer.scale = 1
                parent.onZoomGesture(true)
                parent.onPinch(factor, recognizer.location(in: view), view.bounds.size)
            case .ended, .cancelled, .failed:
                parent.onZoomGesture(false)
            default:
                break
            }
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed:
                let translation = recognizer.translation(in: view)
                recognizer.setTranslation(.zero, in: view)
                parent.onZoomGesture(true)
                parent.onPan(CGSize(width: translation.x, height: translation.y), view.bounds.size)
            case .ended, .cancelled, .failed:
                parent.onZoomGesture(false)
            default:
                break
            }
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onDoubleTap()
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onTap()
        }

        /// Pincement et glissement se reconnaissent ensemble ; rien d'autre ne se reconnaît en même temps.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            (gestureRecognizer === pinch && other === pan) || (gestureRecognizer === pan && other === pinch)
        }
    }
}
