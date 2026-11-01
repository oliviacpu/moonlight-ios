//
//  ShelfModel.swift
//  Shelf (Moonlight TV)
//
//  Observable mirror of ShelfCore for SwiftUI, plus the grouping that turns
//  Sunshine's flat app list into platform shelves. Cards are named
//  "<Platform> · <Title>" by the host; the platform is the text before the
//  first middle dot. Anything without a dot lands under "Other".
//

import Foundation
import SwiftUI

struct ShelfGame: Identifiable, Hashable {
    let appID: String
    let fullName: String
    let title: String
    let platform: String
    var id: String { appID }
}

struct ShelfSection: Identifiable, Hashable {
    let platform: String
    let games: [ShelfGame]
    var id: String { platform }
}

enum ShelfGrouping {
    static let separator = " \u{00B7} "
    static let preferredOrder = ["Dreamcast", "GameCube", "PlayStation 2", "Xbox"]
    static let otherTitle = "Other"

    static func game(for app: ShelfAppInfo) -> ShelfGame {
        let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: separator) {
            let platform = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !platform.isEmpty && !title.isEmpty {
                return ShelfGame(appID: app.appID, fullName: name, title: title, platform: platform)
            }
        }
        return ShelfGame(appID: app.appID, fullName: name, title: name, platform: otherTitle)
    }

    static func sections(for apps: [ShelfAppInfo]) -> [ShelfSection] {
        var byPlatform: [String: [ShelfGame]] = [:]
        for app in apps where !app.hidden {
            let game = game(for: app)
            byPlatform[game.platform, default: []].append(game)
        }
        let platforms = byPlatform.keys.sorted { lhs, rhs in
            let li = preferredOrder.firstIndex(of: lhs) ?? Int.max
            let ri = preferredOrder.firstIndex(of: rhs) ?? Int.max
            if li != ri { return li < ri }
            if lhs == otherTitle { return false }
            if rhs == otherTitle { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return platforms.map { platform in
            let games = byPlatform[platform, default: []].sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return ShelfSection(platform: platform, games: games)
        }
    }
}

@MainActor
final class ShelfModel: ObservableObject {

    enum Phase: Equatable {
        case booting
        case needsHost
        case pairing
        case ready
        case hostOffline
    }

    @Published private(set) var phase: Phase = .booting
    @Published private(set) var pairingPIN: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var hostName: String = ""
    @Published private(set) var hostOnline: Bool = false
    @Published private(set) var runningAppID: String?
    @Published private(set) var sections: [ShelfSection] = []
    @Published private(set) var discoveredHosts: [ShelfHostInfo] = []
    @Published private(set) var isStreaming: Bool = false
    /// Bumped whenever box art may have arrived so cover views reload.
    @Published private(set) var artworkGeneration: Int = 0

    /// Where focus should land when the shelf comes back.
    var lastPlatform: String {
        get { UserDefaults.standard.string(forKey: "shelf.lastPlatform") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "shelf.lastPlatform") }
    }
    var lastAppID: String {
        get { UserDefaults.standard.string(forKey: "shelf.lastAppID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "shelf.lastAppID") }
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let core = ShelfCore.shared
        // ShelfCore calls this on the main thread; hop explicitly so the
        // compiler can see the main-actor isolation.
        core.onChange = { [weak self] in
            Task { @MainActor in
                self?.pull()
            }
        }
        core.boot()
        pull()
    }

    private func pull() {
        let core = ShelfCore.shared
        let newPhase: Phase
        switch core.phase {
        case .booting: newPhase = .booting
        case .needsHost: newPhase = .needsHost
        case .pairing: newPhase = .pairing
        case .ready: newPhase = .ready
        case .hostOffline: newPhase = .hostOffline
        @unknown default: newPhase = .booting
        }
        assign(&phase, newPhase)
        assign(&pairingPIN, core.pairingPIN)
        assign(&statusMessage, core.statusMessage)
        assign(&hostName, core.host?.name ?? "")
        assign(&hostOnline, core.host?.online ?? false)
        assign(&runningAppID, core.host?.runningAppID)
        assign(&isStreaming, core.isStreaming)
        assign(&sections, ShelfGrouping.sections(for: core.apps))
        let hosts = core.discoveredHosts
        let hostSignature = hosts.map { "\($0.uuid)|\($0.name)|\($0.online)|\($0.paired)" }
        if hostSignature != discoveredHostSignature {
            discoveredHostSignature = hostSignature
            discoveredHosts = hosts
        }
        assign(&artworkGeneration, Int(core.artworkVersion))
    }

    private var discoveredHostSignature: [String] = []

    private func assign<T: Equatable>(_ target: inout T, _ value: T) {
        if target != value {
            target = value
        }
    }

    // MARK: Lookups

    var allGames: [ShelfGame] { sections.flatMap { $0.games } }

    func section(named platform: String) -> ShelfSection? {
        sections.first { $0.platform == platform }
    }

    func game(appID: String) -> ShelfGame? {
        allGames.first { $0.appID == appID }
    }

    var runningGame: ShelfGame? {
        guard let runningAppID else { return nil }
        return game(appID: runningAppID)
    }

    // MARK: Actions

    func refresh() {
        ShelfCore.shared.refresh()
    }

    func pair(host: ShelfHostInfo) {
        ShelfCore.shared.pairDiscoveredHost(uuid: host.uuid)
    }

    func cancelPairing() {
        ShelfCore.shared.cancelPairing()
    }

    func forgetHost() {
        ShelfCore.shared.forgetHost()
    }

    func addHost(address: String) async -> String? {
        await withCheckedContinuation { continuation in
            ShelfCore.shared.addHost(address: address) { error in
                continuation.resume(returning: error)
            }
        }
    }

    func quitRunningApp() async -> String? {
        await withCheckedContinuation { continuation in
            ShelfCore.shared.quitRunningApp { error in
                continuation.resume(returning: error)
            }
        }
    }

    /// Starts the stream and returns when the shelf is visible again.
    func play(_ game: ShelfGame) async -> Bool {
        lastPlatform = game.platform
        lastAppID = game.appID
        return await withCheckedContinuation { continuation in
            let started = ShelfAppRoot.presentStream(appID: game.appID) {
                continuation.resume(returning: true)
            }
            if !started {
                continuation.resume(returning: false)
            }
        }
    }
}
