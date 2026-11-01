//
//  ShelfViews.swift
//  Shelf (Moonlight TV)
//
//  Open app → pick a platform → pick a game → stream.
//

import SwiftUI
import UIKit

enum ShelfRoute: Hashable {
    case platform(String)
}

// MARK: - Root

@MainActor
struct ShelfRootView: View {
    @EnvironmentObject private var model: ShelfModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .booting:
                ProgressView().scaleEffect(2)
            case .needsHost:
                FirstRunView()
            case .pairing:
                PairingView()
            case .ready, .hostOffline:
                RailNavigationView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
struct RailNavigationView: View {
    @State private var path: [ShelfRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            RailView(path: $path)
                .navigationDestination(for: ShelfRoute.self) { route in
                    switch route {
                    case .platform(let name):
                        PlatformShelfView(platform: name)
                    }
                }
        }
    }
}

// MARK: - Rail (pick a platform)

@MainActor
struct RailView: View {
    @EnvironmentObject private var model: ShelfModel
    @Binding var path: [ShelfRoute]
    @FocusState private var focusedPlatform: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 90)
                .padding(.top, 60)

            Spacer(minLength: 0)

            if model.sections.isEmpty {
                emptyState
                    .padding(.horizontal, 90)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 48) {
                        ForEach(model.sections) { section in
                            PlatformTile(section: section, cover: firstCover(in: section)) {
                                model.lastPlatform = section.platform
                                path.append(.platform(section.platform))
                            }
                            .focused($focusedPlatform, equals: section.platform)
                        }
                    }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 40)
                }
                .focusSection()
                .defaultFocus($focusedPlatform, initialPlatform)
            }

            Spacer(minLength: 0)

            footer
                .padding(.horizontal, 90)
                .padding(.bottom, 50)
        }
        .background(Color.black)
        .onAppear { model.refresh() }
    }

    private var initialPlatform: String? {
        if model.section(named: model.lastPlatform) != nil {
            return model.lastPlatform
        }
        return model.sections.first?.platform
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(model.hostName.isEmpty ? "Shelf" : model.hostName)
                .font(.system(size: 54, weight: .bold))
            Circle()
                .fill(model.hostOnline ? Color.green : Color.red)
                .frame(width: 16, height: 16)
                .offset(y: -6)
            if let message = model.statusMessage {
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let running = model.runningGame {
                Label("Now playing: \(running.title)", systemImage: "play.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.phase == .hostOffline ? "Monochrome is offline." : "No games yet.")
                .font(.title)
            Text(model.phase == .hostOffline
                 ? "The shelf will fill in when the host is reachable."
                 : "Sunshine has not sent a game list yet.")
                .foregroundStyle(.secondary)
            Button("Try again") { model.refresh() }
        }
    }

    private var footer: some View {
        HStack(spacing: 30) {
            Spacer()
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Button(role: .destructive) {
                model.forgetHost()
            } label: {
                Label("Forget this PC", systemImage: "xmark.circle")
            }
        }
        .font(.callout)
        .focusSection()
    }

    private func firstCover(in section: ShelfSection) -> ShelfGame? {
        section.games.first
    }
}

@MainActor
struct PlatformTile: View {
    let section: ShelfSection
    let cover: ShelfGame?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let cover {
                    CoverImage(game: cover)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 420, height: 300)
                        .clipped()
                        .overlay(
                            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                           startPoint: .center, endPoint: .bottom)
                        )
                } else {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: 420, height: 300)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.platform)
                        .font(.system(size: 36, weight: .bold))
                    Text("\(section.games.count) game\(section.games.count == 1 ? "" : "s")")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
            }
            .frame(width: 420, height: 300)
        }
        .buttonStyle(.card)
    }
}

// MARK: - Shelf (pick a game)

@MainActor
struct PlatformShelfView: View {
    @EnvironmentObject private var model: ShelfModel
    let platform: String

    @FocusState private var focusedAppID: String?
    @State private var pendingGame: ShelfGame?
    @State private var showRunningDialog = false
    @State private var errorMessage: String?
    @State private var isBusy = false

    private let columns = Array(repeating: GridItem(.fixed(240), spacing: 48, alignment: .top), count: 6)

    var body: some View {
        let games = model.section(named: platform)?.games ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    Text(platform)
                        .font(.system(size: 54, weight: .bold))
                    Text("\(games.count)")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let running = model.runningGame {
                        Label("Now playing: \(running.title)", systemImage: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 60)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                    ForEach(games) { game in
                        GameCard(game: game, isRunning: model.runningAppID == game.appID) {
                            tapped(game)
                        }
                        .focused($focusedAppID, equals: game.appID)
                    }
                }
                .padding(.vertical, 30)
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 80)
        }
        .defaultFocus($focusedAppID, initialAppID(in: games))
        .background(Color.black)
        .overlay {
            if isBusy {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    ProgressView().scaleEffect(2)
                }
            }
        }
        .confirmationDialog(
            "\(model.runningGame?.title ?? "A game") is running",
            isPresented: $showRunningDialog,
            titleVisibility: .visible,
            presenting: pendingGame
        ) { game in
            if let running = model.runningGame {
                Button("Resume \(running.title)") { launch(running) }
                Button("Quit and start \(game.title)", role: .destructive) { quitThenLaunch(game) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't start", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func initialAppID(in games: [ShelfGame]) -> String? {
        if games.contains(where: { $0.appID == model.lastAppID }) {
            return model.lastAppID
        }
        return games.first?.appID
    }

    private func tapped(_ game: ShelfGame) {
        if let running = model.runningGame, running.appID != game.appID {
            pendingGame = game
            showRunningDialog = true
        } else {
            launch(game)
        }
    }

    private func launch(_ game: ShelfGame) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            let started = await model.play(game)
            isBusy = false
            if !started {
                errorMessage = "The stream could not be started. Check that \(model.hostName) is online."
            }
        }
    }

    private func quitThenLaunch(_ game: ShelfGame) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            if let error = await model.quitRunningApp() {
                isBusy = false
                errorMessage = error
                return
            }
            isBusy = false
            launch(game)
        }
    }
}

@MainActor
struct GameCard: View {
    let game: ShelfGame
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    CoverImage(game: game)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 240, height: 360)
                        .clipped()
                    if isRunning {
                        Label("Playing", systemImage: "play.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.9), in: Capsule())
                            .foregroundStyle(.black)
                            .padding(12)
                    }
                }
                .frame(width: 240, height: 360)
            }
            .buttonStyle(.card)

            Text(game.title)
                .font(.callout)
                .lineLimit(2)
                .frame(width: 240, alignment: .leading)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cover art

@MainActor
struct CoverImage: View {
    @EnvironmentObject private var model: ShelfModel
    let game: ShelfGame
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)],
                               startPoint: .top, endPoint: .bottom)
                Text(game.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(16)
            }
        }
        .task(id: "\(game.appID)-\(model.artworkGeneration)") {
            guard image == nil else { return }
            guard let path = ShelfCore.shared.boxArtPath(appID: game.appID) else { return }
            let loaded = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: path)?.preparingForDisplay()
            }.value
            if let loaded {
                image = loaded
            }
        }
    }
}

// MARK: - First run

@MainActor
struct FirstRunView: View {
    @EnvironmentObject private var model: ShelfModel
    @State private var address = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            Text("Connect to your PC")
                .font(.system(size: 54, weight: .bold))
            Text("Shelf looks for Sunshine on your network. Pick your PC below, or enter its address.")
                .font(.title3)
                .foregroundStyle(.secondary)

            if let message = model.statusMessage ?? errorMessage {
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.orange)
            }

            if model.discoveredHosts.isEmpty {
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Looking for Sunshine…").foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.discoveredHosts, id: \.uuid) { host in
                        Button {
                            model.pair(host: host)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(host.name).font(.title2)
                                    Text(host.address ?? "").font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(host.paired ? "Paired" : (host.online ? "Online" : "Offline"))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 700)
                        }
                    }
                }
            }

            HStack(spacing: 20) {
                TextField("IP address or hostname", text: $address)
                    .frame(width: 520)
                Button(isAdding ? "Connecting…" : "Add") {
                    guard !isAdding else { return }
                    isAdding = true
                    errorMessage = nil
                    Task {
                        errorMessage = await model.addHost(address: address)
                        isAdding = false
                        if errorMessage == nil { address = "" }
                    }
                }
            }
        }
        .padding(90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }
}

@MainActor
struct PairingView: View {
    @EnvironmentObject private var model: ShelfModel

    var body: some View {
        VStack(spacing: 40) {
            Text("Pair with \(model.hostName)")
                .font(.system(size: 54, weight: .bold))
            if let pin = model.pairingPIN {
                Text(pin)
                    .font(.system(size: 140, weight: .bold, design: .monospaced))
                    .tracking(20)
                Text("Enter this PIN in Sunshine's web UI under PIN.")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().scaleEffect(2)
                Text("Contacting \(model.hostName)…")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") { model.cancelPairing() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
