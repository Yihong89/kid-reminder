import SwiftUI
import AVFoundation

/// ⚡ Pokémon collection — locked slots show ?, spend a stamp to randomly
/// unlock a Pokémon (fanfare plays), click an unlocked one for a big popup.
struct StickersView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var stats: StatsInfo?
    @State private var error: String?
    @State private var revealing: PokemonInfo?
    @State private var popup: PokemonInfo?
    @State private var busy = false
    @State private var currentGen = 0
    @State private var refreshKey = 0

    private var api: APIClient { APIClient(settings: settings) }
    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    var body: some View {
        content
            .navigationTitle("Pokémon")
            .task(id: refreshKey) { await load() }
            .onChange(of: settings.host) { _, _ in refreshKey += 1 }
            .onChange(of: settings.port) { _, _ in refreshKey += 1 }
            .onChange(of: settings.pin) { _, _ in refreshKey += 1 }
            .onChange(of: settings.role) { _, _ in refreshKey += 1 }
            .sheet(item: $revealing) { p in
                RevealView(pokemon: p) { Task { await load() } }
            }
            .sheet(item: $popup) { p in
                DetailPopup(pokemon: p)
            }
    }

    @ViewBuilder
    private var content: some View {
        if settings.host.isEmpty || settings.pin.isEmpty {
            ContentUnavailableView("Not connected",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Enter the server address and PIN in Settings."))
        } else if let error {
            ContentUnavailableView("Can't load collection",
                systemImage: "wifi.exclamationmark",
                description: Text(error))
        } else if let stats {
            VStack(alignment: .leading, spacing: 12) {
                header(stats)
                generationPicker(stats)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(activeDexes(stats), id: \.self) { dex in
                            slot(dex)
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            ProgressView("Loading…").padding()
        }
    }

    private func header(_ stats: StatsInfo) -> some View {
        let gen = activeGen(stats)
        return HStack(spacing: 14) {
            Text("⚡").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(gen.caught)/\(gen.total) \(gen.name) caught")
                    .font(.title3.bold())
                Text(gen.unlocked
                    ? (gen.complete ? "🎉 \(gen.name) complete!" : "⭐ \(stats.stamps.available) stamps to spend")
                    : "🔒 Finish the previous generation to unlock \(gen.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if gen.unlocked && !gen.complete {
                Button {
                    unlock()
                } label: {
                    Label("Unlock (1 ⭐)", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || stats.stamps.available <= 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func generationPicker(_ stats: StatsInfo) -> some View {
        if stats.collection.generations.count > 1 {
            Picker("Generation", selection: $currentGen) {
                ForEach(Array(stats.collection.generations.enumerated()), id: \.element.name) { idx, g in
                    Text(g.complete ? "✅ \(g.name)" : "\(g.name) (\(g.caught)/\(g.total))").tag(idx)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
        }
    }

    private func activeGen(_ stats: StatsInfo) -> StatsInfo.GenerationInfo {
        let i = min(currentGen, stats.collection.generations.count - 1)
        return stats.collection.generations[i]
    }

    private func activeDexes(_ stats: StatsInfo) -> [Int] {
        let gen = activeGen(stats)
        return Array(gen.start...gen.end)
    }

    @ViewBuilder
    private func slot(_ dex: Int) -> some View {
        if let caught = stats?.collection.caught.first(where: { $0.dex == dex }) {
            Button { popup = caught } label: {
                VStack(spacing: 2) {
                    AsyncImage(url: api.spriteURL(dex: dex)) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Color.gray.opacity(0.12)
                    }
                    .frame(width: 56, height: 56)
                    Text(caught.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 2) {
                Text("?").font(.system(size: 34, weight: .bold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func unlock() {
        Task {
            busy = true
            defer { busy = false }
            do {
                let r = try await api.unlock(generation: currentGen)
                playFanfare()
                revealing = r.pokemon
            } catch let e {
                error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
        }
    }

    private func playFanfare() {
        SoundEffects.playFanfare(host: settings.host, port: settings.port)
    }

    private func load() async {
        do {
            stats = try await api.stats()
            error = nil
        } catch let e {
            error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
        }
    }
}

/// ✨ full-screen reveal after unlocking (plays fanfare from the server)
struct RevealView: View {
    let pokemon: PokemonInfo
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text("\(pokemon.name)!")
                .font(.largeTitle.bold())
            StickerImage(dex: pokemon.dex)
                .frame(width: 200, height: 200)
            HStack {
                ForEach(pokemon.types, id: \.self) { t in
                    Text(t).font(.callout).padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                }
            }
            Button("Awesome!") { dismiss(); onDone() }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

/// 🔍 bigger popup with details when clicking an unlocked Pokémon
struct DetailPopup: View {
    let pokemon: PokemonInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("\(pokemon.name)  #\(pokemon.dex)")
                .font(.title2.bold())
            StickerImage(dex: pokemon.dex)
                .frame(width: 220, height: 220)
            HStack {
                ForEach(pokemon.types, id: \.self) { t in
                    Text(t).font(.callout).padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                }
            }
            Text("⭐ Caught — part of your collection")
                .font(.caption).foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

/// Async image for a sprite, given dex (uses the server URL via APIClient).
struct StickerImage: View {
    @EnvironmentObject var settings: SettingsStore
    let dex: Int
    var body: some View {
        let api = APIClient(settings: settings)
        AsyncImage(url: api.spriteURL(dex: dex)) { img in
            img.resizable().scaledToFit()
        } placeholder: {
            Color.gray.opacity(0.12)
        }
    }
}
