import SwiftUI

/// La vidéo plein écran avec son zoom d'affichage seul (pincer, glisser à deux doigts, double tap) et le tap simple qui
/// masque ou rend l'interface. Les décisions sont dans `VideoZoom` ; ici, seulement le branchement des gestes, de l'image
/// et de l'indicateur.
struct ZoomableVideoView: View {
    let session: VideoSession
    /// Ce que fait le tap simple, pour VoiceOver (« Masquer les commandes » ou « Afficher les commandes »).
    let tapLabel: String
    let onTap: @MainActor () -> Void

    @State private var zoom = VideoZoom()
    /// Taille de la vidéo reçue ; nulle tant qu'aucune image n'est arrivée.
    @State private var videoSize = CGSize.zero
    @State private var indicatorVisible = false
    @State private var hideIndicator: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    /// Combien de temps l'indicateur reste après le dernier geste.
    private static let indicatorDuration = Duration.seconds(1)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                VideoView(session: session, onVideoSize: { videoSize = $0 })
                    // Agrandissement autour du centre, puis décalage en points d'écran : c'est le modèle de `VideoZoom`.
                    .scaleEffect(zoom.scale)
                    .offset(zoom.offset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VideoGestureSurface(
                    label: tapLabel,
                    zoomValue: zoom.isZoomed ? "Zoom \(VideoZoom.label(scale: zoom.scale))" : nil,
                    onTap: onTap,
                    onDoubleTap: resetAnimated,
                    onPinch: { factor, anchor, viewSize in
                        zoom.pinch(by: factor, around: anchor, viewSize: viewSize, videoSize: videoSize)
                    },
                    onPan: { translation, viewSize in
                        zoom.pan(by: translation, viewSize: viewSize, videoSize: videoSize)
                    },
                    onZoomGesture: { active in
                        active ? showIndicator() : scheduleIndicatorHide()
                    }
                )
                ZoomIndicator(text: VideoZoom.label(scale: zoom.scale))
                    .padding(.top, proxy.size.height * 0.28)
                    .opacity(indicatorVisible ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // L'iPhone change d'orientation : retour à 1× (les bords de l'image ne sont plus les mêmes).
            .onChange(of: proxy.size.width > proxy.size.height) {
                resetNow()
            }
        }
        .ignoresSafeArea()
        // Quitter l'écran de contrôle, ou l'app qui passe en arrière-plan : retour à 1×. La vie privée, elle, n'y touche pas.
        .onDisappear { resetNow() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                resetNow()
            }
        }
    }

    /// Double tap, ou action VoiceOver : retour animé à l'image entière.
    private func resetAnimated() {
        showIndicator()
        withAnimation(.easeInOut(duration: 0.25)) { zoom.reset() }
        scheduleIndicatorHide()
    }

    private func resetNow() {
        hideIndicator?.cancel()
        indicatorVisible = false
        zoom.reset()
    }

    private func showIndicator() {
        hideIndicator?.cancel()
        hideIndicator = nil
        if !indicatorVisible {
            withAnimation(.easeOut(duration: 0.15)) { indicatorVisible = true }
        }
    }

    private func scheduleIndicatorHide() {
        hideIndicator?.cancel()
        hideIndicator = Task {
            try? await Task.sleep(for: Self.indicatorDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { indicatorVisible = false }
        }
    }
}

/// « 2,4× » : une pastille discrète, lisible sur n'importe quelle image (matière sombre, texte blanc).
private struct ZoomIndicator: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}
