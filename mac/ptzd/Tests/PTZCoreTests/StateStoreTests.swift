import Foundation
import NacelleProtocol
import Testing
@testable import PTZCore

@Suite("state.json")
struct StateStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ptzd-tests-\(UUID().uuidString)")

    private var url: URL {
        directory.appending(path: "state.json")
    }

    @Test("Aller-retour")
    func roundTrip() throws {
        let store = JSONFileStateStore(url: url, log: { _ in })
        let state = PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 33))
        try store.save(state)
        #expect(store.load() == state)
    }

    @Test("L'état natif constaté est retenu : aller-retour, écrit sous « native » (spec § 6.5 bis)")
    func nativeRoundTrip() throws {
        let store = JSONFileStateStore(url: url, log: { _ in })
        let state = PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 33), native: true)
        try store.save(state)
        #expect(store.load() == state)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""native" : true"#))
        #expect(!text.contains("mode"))
    }

    @Test("Un state.json d'avant la vie privée V2 (sans rien) se lit « pas en mode natif »")
    func legacyFileWithoutNative() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"privacy":true,"saved":{"pan":30,"tilt":-10,"zoom":33}}"#.utf8).write(to: url)
        let loaded = JSONFileStateStore(url: url, log: { _ in }).load()
        #expect(loaded.privacy)
        #expect(!loaded.native)
        #expect(loaded.saved == SavedPosition(pan: 30, tilt: -10, zoom: 33))
    }

    @Test("Un state.json du premier prototype : « mode » native se lit « peut-être en mode natif », tilt ou inconnu non")
    func prototypeModeField() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (mode, native) in [("native", true), ("tilt", false), ("flou", false)] {
            try Data(#"{"mode":"\#(mode)","privacy":true,"saved":{"pan":1,"tilt":2,"zoom":null}}"#.utf8).write(to: url)
            let loaded = JSONFileStateStore(url: url, log: { _ in }).load()
            #expect(loaded.privacy)
            #expect(loaded.native == native, "\(mode)")
            #expect(loaded.saved == SavedPosition(pan: 1, tilt: 2, zoom: nil))
        }
        // Réécrit, il perd `mode` au profit de `native`.
        let store = JSONFileStateStore(url: url, log: { _ in })
        try store.save(store.load())
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("mode"))
    }

    @Test("Fichier absent : pas de vie privée")
    func missingFile() {
        let store = JSONFileStateStore(url: url, log: { _ in })
        #expect(store.load() == PersistedState(privacy: false, saved: nil))
    }

    @Test("Fichier illisible : vie privée par précaution, et journalisé")
    func corruptFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{pas du json".utf8).write(to: url)
        let lines = Lines()
        let store = JSONFileStateStore(url: url, log: { lines.append($0) })
        // Et la caméra peut être en mode natif : son état réel sera lu avant tout ordre de position.
        #expect(store.load() == PersistedState(privacy: true, saved: nil, native: true))
        #expect(lines.count == 1)
    }
}

private final class Lines: @unchecked Sendable {
    private var storage: [String] = []

    func append(_ line: String) {
        storage.append(line)
    }

    var count: Int {
        storage.count
    }
}
