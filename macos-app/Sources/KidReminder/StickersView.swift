import SwiftUI

struct StickerInfo: Codable, Identifiable {
    let level: Int
    let dex: Int
    let name: String
    let unlocked: Bool
    var id: Int { level }
}

struct StatsInfo: Codable {
    let totalStamps: Int
    let level: Int
    let stampsForNext: Int?
    let stickers: [StickerInfo]
}

/// 🏅 Achievements: stamp count, level progress, and the unlocked sticker wall.
struct StickersView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var stats: StatsInfo?
    @State private var error: String?

    private var api: APIClient { APIClient(settings: settings) }
    private let stampsPerLevel = 5

    var body: some View {
        Group {
            if settings.host.isEmpty || settings.pin.isEmpty {
                ContentUnavailableView("Not connected",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Enter the server address and PIN in Settings."))
            } else if let error {
                ContentUnavailableView("Can't load achievements",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error))
            } else if let stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Text("🏅").font(.system(size: 40))
                            VStack(alignment: .leading) {
                                Text("Level \(stats.level)")
                                    .font(.title2.bold())
                                Text("\(stats.totalStamps) stamps\(stats.stampsForNext.map { " · \($0 - stats.totalStamps) to next level" } ?? " · max level!")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(value: progress)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                            ForEach(stats.stickers) { s in
                                VStack(spacing: 4) {
                                    AsyncImage(url: api.spriteURL(dex: s.dex)) { img in
                                        img.resizable().scaledToFit()
                                    } placeholder: {
                                        Color.gray.opacity(0.15)
                                    }
                                    .frame(width: 56, height: 56)
                                    .grayscale(s.unlocked ? 0 : 1)
                                    .opacity(s.unlocked ? 1 : 0.35)
                                    Text(s.unlocked ? s.name : "🔒 Lv \(s.level)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView("Loading…").padding()
            }
        }
        .navigationTitle("Stickers")
        .task { await load() }
        .onChange(of: settings.host) { _, _ in Task { await load() } }
        .onChange(of: settings.port) { _, _ in Task { await load() } }
        .onChange(of: settings.pin) { _, _ in Task { await load() } }
        .onChange(of: settings.role) { _, _ in Task { await load() } }
    }

    private var progress: Double {
        guard let stats, stats.stampsForNext != nil else { return 1 }
        let into = Double(stats.totalStamps % stampsPerLevel)
        return min(1, into / Double(stampsPerLevel))
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
