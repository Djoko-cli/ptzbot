import NacelleProtocol
import SwiftUI

/// L'écran unique : la vidéo en plein écran, les commandes par-dessus (spec § 7.2 et § 7.3).
struct ControlScreen: View {
    @Bindable var model: AppModel
    @State private var showSettings = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var privacyOn: Bool {
        model.ptz.state?.privacy ?? false
    }

    /// Nombre de boutons ronds de la rangée du haut, à droite de la roue : son, suivi IA, exposition auto, rec, vie privée.
    private static let rightButtonCount = 5
    /// Largeur du groupe de droite plus un écart, et de la roue à gauche plus un écart : les marges du badge et du bandeau
    /// en paysage.
    private static let rightGroupMargin = CGFloat(rightButtonCount) * 44 + CGFloat(rightButtonCount - 1) * 10 + 12
    private static let leftWheelMargin: CGFloat = 44 + 12

    /// En portrait (hauteur « regular »), la rangée du haut tient tous ses boutons : le bandeau et le badge
    /// d'enregistrement passent chacun sur leur ligne en dessous. En paysage, ils restent dans la rangée.
    private var bannerOnOwnRow: Bool {
        verticalSizeClass == .regular
    }

    /// Mode épuré (tap sur la vidéo) : seuls le bouton rec et le badge restent, pendant un enregistrement.
    private var clean: Bool {
        model.cleanFeed
    }

    /// Le bouton rec, en mode épuré : visible seulement pendant un enregistrement ou sa sauvegarde.
    private var recordButtonShown: Bool {
        !clean || model.recording != .idle
    }

    /// Le badge d'enregistrement et le bandeau, côte à côte (paysage).
    private var landscapeStatusRow: some View {
        HStack(spacing: 10) {
            if case let .recording(since) = model.recording {
                RecordingBadge(since: since)
            }
            if let banner {
                banner
            }
        }
    }

    private var banner: BannerView? {
        guard let text = clean ? model.cleanFeedBannerText : model.bannerText else { return nil }
        return BannerView(
            text: text,
            retry: model.showsRetry ? { Task { await model.retrySave() } } : nil,
            dismiss: model.showsRetry ? { model.dismissUnsavedClipBanner() } : nil
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // La vidéo, son zoom d'affichage (pincer, glisser à deux doigts, double tap) et le tap sur la vidéo nue, qui masque
            // ou rend l'interface. Sous les commandes : le joystick, le zoom et les boutons gardent leurs propres gestes.
            ZoomableVideoView(
                session: model.video,
                tapLabel: clean ? "Afficher les commandes" : "Masquer les commandes",
                onTap: { withAnimation(.easeInOut(duration: 0.25)) { model.toggleCleanFeed() } }
            )
            VStack {
                ZStack(alignment: .top) {
                    // Masqués sans quitter la mise en page : le bouton rec garde sa place en mode épuré.
                    HStack(alignment: .top) {
                        settingsButton
                            .hiddenInCleanFeed(clean)
                        Spacer(minLength: 12)
                        HStack(spacing: 10) {
                            soundButton
                                .hiddenInCleanFeed(clean)
                            aiButton
                                .hiddenInCleanFeed(clean)
                            // Juste à côté du bouton rec, de la même famille (spec § 6.11).
                            exposureButton
                                .hiddenInCleanFeed(clean)
                            recordButton
                                .hiddenInCleanFeed(!recordButtonShown)
                            privacyButton
                                .hiddenInCleanFeed(clean)
                        }
                    }
                    // Paysage : le badge d'enregistrement et le bandeau, centrés sur toute la largeur de l'écran (et non
                    // entre la roue et les cinq boutons). La marge de chaque côté vaut la largeur du groupe de droite
                    // (5 × 44 + 4 × 10 points) plus un écart : ils ne recouvrent jamais un bouton. Quand la place manque
                    // (iPhone SE ou mini), ils se centrent dans l'espace libre entre la roue et les boutons, plus large
                    // que sous deux marges égales.
                    if !bannerOnOwnRow {
                        ViewThatFits(in: .horizontal) {
                            landscapeStatusRow
                                .padding(.horizontal, Self.rightGroupMargin)
                            landscapeStatusRow
                                .padding(.leading, Self.leftWheelMargin)
                                .padding(.trailing, Self.rightGroupMargin)
                        }
                    }
                }
                // Portrait : le bandeau, centré sur sa ligne, au-dessus du badge.
                if bannerOnOwnRow, let banner {
                    banner
                }
                // Portrait : le badge, sous la rangée du haut, au centre.
                if bannerOnOwnRow, case let .recording(since) = model.recording {
                    RecordingBadge(since: since)
                }
                Spacer()
                HStack(alignment: .bottom) {
                    JoystickView(
                        isEnabled: model.controlsEnabled,
                        onChange: { model.ptz.setJoystick($0) },
                        onRelease: { model.ptz.setJoystick(.zero) }
                    )
                    .hiddenInCleanFeed(clean)
                    Spacer()
                    // Entre le joystick et le zoom. Masqué en mode épuré comme les autres commandes.
                    SpeakButton(
                        isSpeaking: model.isSpeaking,
                        isPreparing: model.isPreparingSpeak,
                        dimmed: model.speakDimmed,
                        level: model.micLevel,
                        onPress: { model.pressSpeak() },
                        onRelease: { model.releaseSpeak() }
                    )
                    .hiddenInCleanFeed(clean)
                    Spacer()
                    ZoomSlider(
                        value: model.ptz.state?.zoom,
                        isEnabled: model.controlsEnabled,
                        onChange: { model.ptz.setZoom($0) }
                    )
                    .hiddenInCleanFeed(clean)
                }
            }
            .padding(20)
        }
        .statusBarHidden(clean)
        .persistentSystemOverlays(clean ? .hidden : .automatic)
        .sensoryFeedback(.success, trigger: model.ptz.state?.privacy) { old, new in
            // Seulement entre deux états connus : pas à la coupure ni à la reconnexion.
            old != nil && new != nil && old != new
        }
        .sensoryFeedback(.success, trigger: model.savedCount)
        .sheet(isPresented: $showSettings) {
            SettingsView(
                settings: $model.settings,
                isPaired: model.ptz.isPaired,
                onPair: { model.pair(with: $0) },
                onForget: { model.forgetPairing() }
            )
        }
        .fullScreenCover(isPresented: Binding(get: { model.needsPairing }, set: { _ in })) {
            PairingScreen(model: model)
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Réglages")
    }

    private var soundButton: some View {
        Button {
            model.soundWanted.toggle()
        } label: {
            Image(systemName: model.soundPlaying ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.soundToggleEnabled)
        .opacity(model.soundToggleEnabled ? 1 : 0.4)
        .accessibilityLabel(soundLabel)
    }

    private var soundLabel: String {
        if privacyOn {
            return "Son coupé en vie privée"
        }
        if !model.soundToggleEnabled {
            return "Son coupé"
        }
        return model.soundWanted ? "Couper le son" : "Activer le son"
    }

    private var aiButton: some View {
        Button {
            model.toggleAITracking()
        } label: {
            Group {
                if model.aiTrackingBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: model.aiTrackingOn ? "person.crop.square.fill" : "person.crop.square")
                        .font(.title3)
                }
            }
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.aiToggleEnabled)
        .opacity(model.aiToggleEnabled || model.aiTrackingBusy ? 1 : 0.4)
        .accessibilityLabel(model.aiTrackingBusy ? "Suivi IA en cours de changement" : model.aiTrackingOn ? "Couper le suivi IA" : "Allumer le suivi IA")
    }

    /// Le fond des boutons ronds qui peuvent être « actifs » (rec, vie privée, exposition auto) : la matière quand ils sont
    /// inactifs, une couleur quand ils sont actifs (rouge par défaut, jaune soleil pour l'exposition). Un seul style, pour
    /// que ces boutons restent de la même famille.
    private func activeBackground(_ active: Bool, color: Color = .red) -> AnyShapeStyle {
        active ? AnyShapeStyle(color.opacity(0.8)) : AnyShapeStyle(.ultraThinMaterial)
    }

    /// Exposition automatique (spec § 6.11) : même forme, même taille et même style d'état actif et inactif que le bouton
    /// rec. Grisé sans connexion, sans caméra, sans SDK sur le Mac ou avec un ptzd ancien ; utilisable en vie privée.
    private var exposureButton: some View {
        Button {
            model.toggleAutoExposure()
        } label: {
            Image(systemName: model.autoExposureOn ? "sun.max.fill" : "sun.max")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(activeBackground(model.autoExposureOn, color: .yellow), in: Circle())
        }
        // Jaune soleil quand l'exposition auto est active (et non le rouge de l'enregistrement) : l'icône passe au noir sur
        // ce fond clair, lisible en mode clair comme en mode sombre ; blanche sur la matière quand elle est inactive.
        .foregroundStyle(model.autoExposureOn ? Color.black : Color.white)
        .disabled(!model.autoExposureToggleEnabled)
        .opacity(model.autoExposureToggleEnabled ? 1 : 0.4)
        .accessibilityLabel("Exposition auto")
        .accessibilityValue(model.autoExposureOn ? "activée" : "désactivée")
        .accessibilityHint(Self.autoExposureHint(model.ptz.state?.autoExposure))
    }

    /// L'indication VoiceOver du bouton d'exposition automatique, selon ce que ptzd publie : ce que fait le bouton, ou
    /// pourquoi il est grisé.
    nonisolated static func autoExposureHint(_ exposure: AutoExposure?) -> String {
        switch exposure {
        case .on: "Désactive l'exposition automatique et remet le réglage d'avant"
        case .off: "Laisse la caméra régler elle-même l'exposition"
        case .unavailable: "Indisponible : demande le SDK OBSBOT sur le Mac"
        case nil: "Indisponible : demande une mise à jour de PTZBot sur le Mac"
        }
    }

    private var isRecording: Bool {
        if case .recording = model.recording { true } else { false }
    }

    /// Atténué quand il est inactif, ou quand l'accès à Photos est refusé (il reste touchable : il explique).
    private var recordDimmed: Bool {
        switch model.recording {
        case .recording, .saving: false
        case .idle: !model.recordToggleEnabled || model.photoAccessDenied
        }
    }

    private var recordButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            Group {
                if model.recording == .saving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "record.circle")
                        .font(.title3)
                }
            }
            .frame(width: 44, height: 44)
            .background(activeBackground(isRecording), in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.recordToggleEnabled)
        .opacity(recordDimmed ? 0.4 : 1)
        .accessibilityLabel(isRecording ? "Arrêter l'enregistrement" : model.recording == .saving ? "Enregistrement en cours de sauvegarde" : "Enregistrer")
    }

    private var privacyButton: some View {
        Button {
            model.ptz.setPrivacy(!privacyOn)
        } label: {
            Image(systemName: privacyOn ? "eye.slash.fill" : "eye.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(activeBackground(privacyOn), in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.privacyToggleEnabled)
        .opacity(model.privacyToggleEnabled ? 1 : 0.4)
        .accessibilityLabel(privacyOn ? "Quitter la vie privée" : "Vie privée")
        .accessibilityHint(Self.privacyHint(on: privacyOn))
    }

    /// L'indication VoiceOver du bouton de vie privée, selon son état (spec § 6.5 bis) : l'entrée ne coupe l'image et le
    /// micro qu'avec le SDK sur le Mac ; la sortie ramène toujours la caméra à sa position d'avant.
    nonisolated static func privacyHint(on: Bool) -> String {
        on
            ? "Ramène la caméra à sa position d'avant la vie privée"
            : "Détourne l'objectif et, avec le SDK OBSBOT sur le Mac, coupe l'image et le micro de la caméra"
    }
}

/// « Maintenir pour parler » (spec parler § 6.1) : un grand bouton rond qui parle tant que le doigt reste posé.
/// Rouge dès le toucher, avec un anneau qui tourne tant que le micro se prépare (la session audio bascule, ce qui prend
/// un instant) ; puis une petite jauge du niveau du micro, quand les premières trames sont captées : c'est le moment de
/// parler. Atténué (mais touchable : un appui dit pourquoi)
/// quand parler est impossible.
private struct SpeakButton: View {
    let isSpeaking: Bool
    /// Le micro n'est pas encore en direct : anneau tournant, jauge muette.
    let isPreparing: Bool
    let dimmed: Bool
    let level: Float
    let onPress: () -> Void
    let onRelease: () -> Void
    /// Le doigt est posé, d'après `PressSurface` : le toucher brut, annulé par le système compris (alerte de permission,
    /// Centre de contrôle, appel).
    @State private var pressing = false

    /// Rouge dès que le doigt se pose, sans attendre la bascule audio du modèle (banc du 10/10 : le bouton paraissait
    /// lent alors que le son était capté dès l'appui).
    private var held: Bool {
        (pressing && !dimmed) || isSpeaking
    }

    /// L'anneau tourne du toucher jusqu'au micro en direct.
    private var showsRing: Bool {
        held && (isPreparing || !isSpeaking)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(held ? AnyShapeStyle(.red.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial))
            VStack(spacing: 6) {
                Image(systemName: held ? "mic.fill" : "mic")
                    .font(.title2)
                if isSpeaking, !isPreparing {
                    // La jauge : une barre qui suit le niveau du micro.
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: 36, height: 5)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: 36 * CGFloat(min(max(level, 0), 1)), height: 5)
                        }
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white)
            if showsRing {
                PreparingRing()
            }
        }
        .frame(width: 72, height: 72)
        .contentShape(Circle())
        .opacity(dimmed ? 0.4 : 1)
        .overlay {
            PressSurface { now in
                pressing = now
                if now {
                    onPress()
                } else {
                    onRelease()
                }
            }
            .clipShape(Circle())
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: held)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPreparing ? "Préparation du micro" : isSpeaking ? "Parole en cours" : "Maintenir pour parler")
        .accessibilityHint("Parler par les haut-parleurs du Mac")
        // Maintenir : VoiceOver laisse passer le toucher tel quel (double toucher prolongé).
        .accessibilityAddTraits([.isButton, .allowsDirectInteraction])
    }
}

/// L'anneau qui tourne autour du bouton « parler » pendant la préparation du micro. Immobile (arc fixe) quand l'utilisateur
/// a demandé de réduire les animations.
private struct PreparingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
                .padding(3)
        }
        .accessibilityHidden(true)
    }
}

/// Le bandeau d'état, en haut de l'écran. `retry` : « Réessayer », pour une vidéo qui n'est pas dans Photos ;
/// `dismiss` : la croix qui ferme ce bandeau (le fichier reste, effacé au bout de 7 jours).
private struct BannerView: View {
    let text: String
    var retry: (() -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            if let retry {
                Button("Réessayer", action: retry)
                    .font(.subheadline.weight(.bold))
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Fermer")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// « ● 00:42 » : le point rouge pulse, le chronomètre garde des chiffres de largeur fixe (spec enregistrement § 3).
private struct RecordingBadge: View {
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(since))
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(dimmed ? 0.25 : 1)
                Text(RecordingFormat.clock(seconds: seconds))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RecordingFormat.spoken(seconds: seconds))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
    }
}

private extension View {
    /// Masqué en mode épuré : transparent et sans toucher, mais à sa place (rien ne bouge autour).
    func hiddenInCleanFeed(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}
