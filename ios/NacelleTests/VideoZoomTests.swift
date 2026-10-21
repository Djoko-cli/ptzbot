import CoreGraphics
import Testing
@testable import Nacelle

@Suite("Zoom de l'affichage")
struct VideoZoomTests {
    /// Un écran en paysage de proportions 16:9, que la vidéo remplit exactement (pas de bandes).
    private let landscape = CGSize(width: 800, height: 450)
    private let video = CGSize(width: 1920, height: 1080)
    /// Le même iPhone en portrait : la vidéo 16:9 laisse des bandes noires en haut et en bas.
    private let portrait = CGSize(width: 400, height: 800)

    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < 0.0001
    }

    @Test("Au départ : 1×, sans décalage, image entière")
    func initialState() {
        let zoom = VideoZoom()
        #expect(zoom.scale == 1)
        #expect(zoom.offset == .zero)
        #expect(!zoom.isZoomed)
    }

    @Test("Le zoom maximal est 8×")
    func maxScaleIsEight() {
        #expect(VideoZoom.minScale == 1)
        #expect(VideoZoom.maxScale == 8)
    }

    @Test("Le pincement agrandit, et le facteur reste entre 1× et 8×")
    func scaleIsClamped() {
        var zoom = VideoZoom()
        zoom.pinch(by: 2, around: CGPoint(x: 400, y: 225), viewSize: landscape, videoSize: video)
        #expect(close(zoom.scale, 2))
        #expect(zoom.isZoomed)
        zoom.pinch(by: 10, around: CGPoint(x: 400, y: 225), viewSize: landscape, videoSize: video)
        #expect(zoom.scale == 8)
        #expect(zoom.scale == VideoZoom.maxScale)
        zoom.pinch(by: 0.001, around: CGPoint(x: 400, y: 225), viewSize: landscape, videoSize: video)
        #expect(zoom.scale == VideoZoom.minScale)
        #expect(zoom.offset == .zero)
        #expect(!zoom.isZoomed)
    }

    @Test("Le point sous les doigts reste sous les doigts")
    func anchorStaysUnderFingers() {
        var zoom = VideoZoom()
        let anchor = CGPoint(x: 600, y: 150)
        // Le point de la vue entière qui est sous les doigts avant le zoom : à 1×, c'est le point lui-même.
        zoom.pinch(by: 2, around: anchor, viewSize: landscape, videoSize: video)
        let center = CGPoint(x: 400, y: 225)
        let shown = CGPoint(
            x: center.x + zoom.offset.width + zoom.scale * (anchor.x - center.x),
            y: center.y + zoom.offset.height + zoom.scale * (anchor.y - center.y)
        )
        #expect(close(shown.x, anchor.x))
        #expect(close(shown.y, anchor.y))
    }

    @Test("Un pincement au centre ne décale pas l'image")
    func centeredPinchKeepsOffsetZero() {
        var zoom = VideoZoom()
        zoom.pinch(by: 3, around: CGPoint(x: 400, y: 225), viewSize: landscape, videoSize: video)
        #expect(zoom.offset == .zero)
    }

    @Test("Un pincement dans un coin est borné : l'image ne sort jamais de la vue")
    func pinchInCornerIsBounded() {
        var zoom = VideoZoom()
        zoom.pinch(by: 4, around: CGPoint(x: 800, y: 450), viewSize: landscape, videoSize: video)
        // Image 4× : elle dépasse de 3 fois la vue ; le décalage maximal est la moitié de ce dépassement.
        #expect(close(zoom.offset.width, -1200))
        #expect(close(zoom.offset.height, -675))
        zoom.pinch(by: 1, around: CGPoint(x: 0, y: 0), viewSize: landscape, videoSize: video)
        #expect(abs(zoom.offset.width) <= 1200)
        #expect(abs(zoom.offset.height) <= 675)
    }

    @Test("À 8×, le coin est borné lui aussi")
    func pinchInCornerAtMaxScale() {
        var zoom = VideoZoom()
        zoom.pinch(by: 8, around: CGPoint(x: 800, y: 450), viewSize: landscape, videoSize: video)
        // Image 8× : elle dépasse de 7 fois la vue ; le décalage maximal est la moitié de ce dépassement.
        #expect(close(zoom.offset.width, -2800))
        #expect(close(zoom.offset.height, -1575))
        zoom.pan(by: CGSize(width: 9000, height: 9000), viewSize: landscape, videoSize: video)
        #expect(close(zoom.offset.width, 2800))
        #expect(close(zoom.offset.height, 1575))
    }

    @Test("Le glissement déplace l'image zoomée, dans ses bords")
    func panIsBounded() {
        var zoom = VideoZoom()
        zoom.pinch(by: 2, around: CGPoint(x: 400, y: 225), viewSize: landscape, videoSize: video)
        zoom.pan(by: CGSize(width: 100, height: -50), viewSize: landscape, videoSize: video)
        #expect(close(zoom.offset.width, 100))
        #expect(close(zoom.offset.height, -50))
        // 2× : l'image dépasse de 800 × 450 points en tout, soit au plus 400 et 225 de décalage.
        zoom.pan(by: CGSize(width: 5000, height: 5000), viewSize: landscape, videoSize: video)
        #expect(close(zoom.offset.width, 400))
        #expect(close(zoom.offset.height, 225))
        zoom.pan(by: CGSize(width: -5000, height: -5000), viewSize: landscape, videoSize: video)
        #expect(close(zoom.offset.width, -400))
        #expect(close(zoom.offset.height, -225))
    }

    @Test("À 1×, le glissement ne fait rien")
    func panDoesNothingAtOne() {
        var zoom = VideoZoom()
        zoom.pan(by: CGSize(width: 80, height: 80), viewSize: landscape, videoSize: video)
        #expect(zoom == VideoZoom())
    }

    @Test("Un doigt ne déplace l'image que si elle est zoomée ; deux doigts, toujours")
    func panIsAcceptedOnlyWhenUseful() {
        var zoom = VideoZoom()
        #expect(!zoom.acceptsPan(touchCount: 1))
        #expect(zoom.acceptsPan(touchCount: 2))
        zoom.pinch(by: 2, around: CGPoint(x: 400, y: 225), viewSize: landscape, videoSize: video)
        #expect(zoom.acceptsPan(touchCount: 1))
        #expect(zoom.acceptsPan(touchCount: 2))
        #expect(!zoom.acceptsPan(touchCount: 0))
        zoom.reset()
        #expect(!zoom.acceptsPan(touchCount: 1))
    }

    @Test("Portrait : l'image 16:9 ne glisse que dans le sens où elle dépasse")
    func letterboxedVideo() {
        var zoom = VideoZoom()
        zoom.pinch(by: 2, around: CGPoint(x: 200, y: 400), viewSize: portrait, videoSize: video)
        zoom.pan(by: CGSize(width: 5000, height: 5000), viewSize: portrait, videoSize: video)
        // Largeur : l'image remplit la vue, donc à 2× elle dépasse de 400, soit 200 de décalage.
        #expect(close(zoom.offset.width, 200))
        // Hauteur : l'image fait 225 points, 450 à 2× : moins que la vue de 800, donc elle reste centrée.
        #expect(zoom.offset.height == 0)
    }

    @Test("Taille de la vidéo inconnue : les bords de la vue servent de bornes")
    func unknownVideoSize() {
        var zoom = VideoZoom()
        zoom.pinch(by: 2, around: CGPoint(x: 400, y: 225), viewSize: landscape, videoSize: .zero)
        zoom.pan(by: CGSize(width: 5000, height: 0), viewSize: landscape, videoSize: .zero)
        #expect(close(zoom.offset.width, 400))
    }

    @Test("La remise à 1× rend l'image entière")
    func resetBringsBackWholeImage() {
        var zoom = VideoZoom()
        zoom.pinch(by: 3, around: CGPoint(x: 700, y: 100), viewSize: landscape, videoSize: video)
        zoom.pan(by: CGSize(width: -20, height: 30), viewSize: landscape, videoSize: video)
        zoom.reset()
        #expect(zoom == VideoZoom())
    }

    @Test("Un facteur ou une taille absurdes sont ignorés")
    func invalidInputsAreIgnored() {
        var zoom = VideoZoom()
        zoom.pinch(by: 0, around: .zero, viewSize: landscape, videoSize: video)
        zoom.pinch(by: -2, around: .zero, viewSize: landscape, videoSize: video)
        zoom.pinch(by: .nan, around: .zero, viewSize: landscape, videoSize: video)
        zoom.pinch(by: 2, around: .zero, viewSize: .zero, videoSize: video)
        #expect(zoom == VideoZoom())
    }

    @Test("Taille de l'image dans la vue : sans rognage")
    func contentSize() {
        #expect(VideoZoom.contentSize(video: video, in: portrait) == CGSize(width: 400, height: 225))
        let wide = VideoZoom.contentSize(video: video, in: CGSize(width: 800, height: 600))
        #expect(close(wide.width, 800) && close(wide.height, 450))
        let tall = VideoZoom.contentSize(video: video, in: CGSize(width: 800, height: 400))
        #expect(abs(tall.width - 711.1111) < 0.001)
        #expect(close(tall.height, 400))
        #expect(VideoZoom.contentSize(video: .zero, in: landscape) == landscape)
    }

    @Test("Indicateur : une décimale, virgule à la française, entier sans décimale")
    func label() {
        #expect(VideoZoom.label(scale: 1) == "1×")
        #expect(VideoZoom.label(scale: 2) == "2×")
        #expect(VideoZoom.label(scale: 2.4) == "2,4×")
        #expect(VideoZoom.label(scale: 2.43) == "2,4×")
        #expect(VideoZoom.label(scale: 3.96) == "4×")
        #expect(VideoZoom.label(scale: 4) == "4×")
        #expect(VideoZoom.label(scale: 7.96) == "8×")
        #expect(VideoZoom.label(scale: 8) == "8×")
        #expect(VideoZoom.label(scale: 1.04) == "1×")
    }
}
