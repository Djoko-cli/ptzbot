import SwiftUI
@preconcurrency import WebRTC

/// L'image de la caméra, sans rognage (spec § 7.2).
struct VideoView: UIViewRepresentable {
    let session: VideoSession
    /// Appelé à la première image et à chaque changement de taille de la vidéo reçue : le zoom en déduit les bords de
    /// l'image dans la vue.
    var onVideoSize: (CGSize) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onVideoSize: onVideoSize)
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .black
        view.delegate = context.coordinator
        session.attach(renderer: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.onVideoSize = onVideoSize
    }

    /// Reçoit la taille de la vidéo (WebRTC l'appelle sur le fil principal).
    @MainActor
    final class Coordinator: NSObject, @preconcurrency RTCVideoViewDelegate {
        var onVideoSize: (CGSize) -> Void

        init(onVideoSize: @escaping (CGSize) -> Void) {
            self.onVideoSize = onVideoSize
        }

        func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            onVideoSize(size)
        }
    }
}
