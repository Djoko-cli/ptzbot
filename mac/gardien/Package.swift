// swift-tools-version: 6.0
import PackageDescription

/// gardien : lance un programme en processus enfant et l'arrête quand son parent disparaît (spec B3 § 3.2). PTZBot
/// lance go2rtc par lui : après un plantage de PTZBot, go2rtc ne reste pas orphelin, la caméra ouverte.
/// `GardienCore` porte toute la logique ; l'exécutable ne fait que lire les options et rendre la fin du programme.
let package = Package(
    name: "gardien",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "GardienCore"),
        .executableTarget(name: "gardien", dependencies: ["GardienCore"]),
        .testTarget(name: "GardienCoreTests", dependencies: ["GardienCore"]),
        // Le faux ffmpeg des tests (un exécutable nommé `ffmpeg`) ; jamais embarqué : PTZBot ne construit que `gardien`.
        .executableTarget(name: "ffmpeg", path: "Tests/FauxFFmpeg"),
    ]
)
