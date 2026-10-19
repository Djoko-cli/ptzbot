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

    @Test("Le mode de la vie privée est retenu : aller-retour en natif")
    func nativeModeRoundTrip() throws {
        let store = JSONFileStateStore(url: url, log: { _ in })
        let state = PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 33), mode: .native)
        try store.save(state)
        #expect(store.load() == state)
        #expect(store.load().mode == .native)
    }

    @Test("Un state.json d'avant la vie privée V2 (sans mode) se lit « tilt » (spec § 6.5 bis)")
    func legacyFileWithoutMode() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"privacy":true,"saved":{"pan":30,"tilt":-10,"zoom":33}}"#.utf8).write(to: url)
        let loaded = JSONFileStateStore(url: url, log: { _ in }).load()
        #expect(loaded.privacy)
        #expect(loaded.mode == .tilt)
        #expect(loaded.saved == SavedPosition(pan: 30, tilt: -10, zoom: 33))
    }

    @Test("Un mode inconnu se lit « tilt » : le repli qui ne dépend pas du SDK")
    func unknownMode() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"mode":"flou","privacy":true}"#.utf8).write(to: url)
        let loaded = JSONFileStateStore(url: url, log: { _ in }).load()
        #expect(loaded.privacy)
        #expect(loaded.mode == .tilt)
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
        #expect(store.load() == PersistedState(privacy: true, saved: nil))
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
