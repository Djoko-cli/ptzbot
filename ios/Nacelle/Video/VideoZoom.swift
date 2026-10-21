import CoreGraphics

/// Le zoom numérique de l'affichage (backlog « Pincer pour zoomer ») : un agrandissement de la vue, de 1× à 8×, et le
/// décalage de l'image agrandie. Aucun ordre n'est envoyé à la caméra : ni HomeKit, ni les enregistrements, ni le Mac ne
/// le voient. La logique est pure (sans UIKit) ; la vue qui l'affiche reste mince.
///
/// Le modèle : le point `p` de la vue entière s'affiche en `centre + décalage + échelle × (p − centre)`, le centre étant
/// celui de la vue. L'agrandissement et le décalage se règlent donc indépendamment, et l'on garde le point sous les doigts.
struct VideoZoom: Equatable, Sendable {
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 8

    /// Le facteur d'agrandissement, de `minScale` à `maxScale`.
    private(set) var scale: CGFloat = 1
    /// Le décalage de l'image agrandie par rapport au centre de la vue, en points d'écran. Toujours nul à 1×.
    private(set) var offset: CGSize = .zero

    /// Vrai dès que l'image est agrandie (le facteur est borné : à 1× il vaut exactement 1).
    var isZoomed: Bool {
        scale > Self.minScale
    }

    /// Pincement : multiplie le facteur par `factor` (borné à 1×–8×) en gardant fixe, sous les doigts, le point de l'image
    /// en `anchor` (coordonnées de la vue). Appelé par petits pas : `factor` est le rapport depuis l'appel précédent.
    mutating func pinch(by factor: CGFloat, around anchor: CGPoint, viewSize: CGSize, videoSize: CGSize) {
        guard factor.isFinite, factor > 0, Self.isUsable(viewSize) else { return }
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        let ratio = newScale / scale
        let ax = anchor.x - viewSize.width / 2
        let ay = anchor.y - viewSize.height / 2
        offset = CGSize(
            width: ax - ratio * (ax - offset.width),
            height: ay - ratio * (ay - offset.height)
        )
        scale = newScale
        clampOffset(viewSize: viewSize, videoSize: videoSize)
    }

    /// Un glissement de `touchCount` doigts doit-il déplacer l'image ? Deux doigts, toujours (ils accompagnent le pincement,
    /// qui part de 1×) ; un seul doigt, seulement quand l'image est agrandie : à 1× il n'y a rien à déplacer.
    func acceptsPan(touchCount: Int) -> Bool {
        touchCount >= 2 || (touchCount == 1 && isZoomed)
    }

    /// Glissement à un ou deux doigts : déplace l'image agrandie de `translation` (points d'écran), sans jamais en sortir.
    mutating func pan(by translation: CGSize, viewSize: CGSize, videoSize: CGSize) {
        guard Self.isUsable(viewSize), translation.width.isFinite, translation.height.isFinite else { return }
        offset = CGSize(width: offset.width + translation.width, height: offset.height + translation.height)
        clampOffset(viewSize: viewSize, videoSize: videoSize)
    }

    /// Retour à l'image entière.
    mutating func reset() {
        scale = Self.minScale
        offset = .zero
    }

    /// Les bords de l'image ne quittent jamais ceux de la vue : sur chaque axe, le décalage est borné par la moitié de ce
    /// que l'image agrandie dépasse de la vue. Si elle ne la dépasse pas (bandes noires d'une vidéo 16:9 en portrait),
    /// elle reste centrée sur cet axe.
    private mutating func clampOffset(viewSize: CGSize, videoSize: CGSize) {
        let content = Self.contentSize(video: videoSize, in: viewSize)
        let maxX = max(0, (content.width * scale - viewSize.width) / 2)
        let maxY = max(0, (content.height * scale - viewSize.height) / 2)
        offset = CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    /// La taille de l'image dans la vue, sans rognage (`scaleAspectFit`). Taille de la vidéo inconnue : toute la vue.
    static func contentSize(video: CGSize, in view: CGSize) -> CGSize {
        guard isUsable(video), isUsable(view) else { return view }
        let fit = min(view.width / video.width, view.height / video.height)
        return CGSize(width: video.width * fit, height: video.height * fit)
    }

    /// L'indicateur du facteur, à une décimale et à la française : « 2,4× », « 2× ».
    static func label(scale: CGFloat) -> String {
        guard scale.isFinite else { return "1×" }
        let tenths = Int((scale * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)×" : "\(tenths / 10),\(tenths % 10)×"
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
