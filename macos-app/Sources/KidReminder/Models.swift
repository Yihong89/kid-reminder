import Foundation

struct KidTask: Identifiable, Codable, Equatable {
    let id: Int
    let title: String
    let emoji: String
    let repeatType: String   // "daily" | "weekly" | "biweekly" | "monthly" | "once"
    let done: Bool
    let minutes: Int
    let targetDate: String?
    let countdownEnabled: Bool
    let countdownStart: Int
    let daysLeft: Int?
    let createdBy: String
    let parentOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, emoji, done, minutes, targetDate, countdownEnabled, countdownStart, daysLeft, createdBy, parentOnly
        case repeatType = "repeat"
    }

    /// True when the task is 🔒 parent-only (hidden from the kid).
    var isParentOnly: Bool { parentOnly == true }

    /// Human-friendly countdown label, mirroring the web panel.
    var countdownText: String? {
        guard countdownEnabled, let d = daysLeft else { return nil }
        if d < 0 { return "⏰ \(-d)d ago" }
        if d == 0 { return "📅 Today!" }
        if d <= countdownStart { return "⏳ \(d)d" }
        return "📅 in \(d)d"
    }

    /// Repeat badge label, mirroring the web panel (nil for the default "daily").
    var repeatBadge: String? {
        repeatType == "daily" ? nil : repeatType
    }
}

struct TasksResponse: Codable {
    let today: String
    let date: String
    let tasks: [KidTask]
    let allDone: Bool?
    let stamped: Bool?
}

/// Curated emoji choices for the add-task form (matches the web panel).
let EmojiChoices: [(String, String)] = [
    ("", "none"), ("📚", "homework"), ("📝", "writing"), ("✏️", "write"), ("📖", "read"), ("📒", "notes"),
    ("🗣️", "oral"), ("🧮", "math"), ("📐", "geometry"), ("🔬", "science"), ("🧪", "lab"), ("🌍", "geography"),
    ("🎨", "art"), ("🎹", "piano"), ("🎸", "guitar"), ("🎤", "singing"), ("🎭", "drama"), ("🏊", "swimming"), ("⚽", "sports"),
    ("🧠", "focus"), ("⭐", "star"), ("📅", "deadline"), ("⏰", "time"),
]

struct PokemonInfo: Codable, Identifiable {
    let dex: Int
    let name: String
    let types: [String]
    var id: Int { dex }
}

struct StatsInfo: Codable {
    let stamps: StampBalance
    let collection: CollectionInfo
    struct StampBalance: Codable { let earned: Int; let spent: Int; let available: Int }
    struct CollectionInfo: Codable { let total: Int; let caught: [PokemonInfo]; let generations: [GenerationInfo] }
    struct GenerationInfo: Codable {
        let name: String
        let start: Int
        let end: Int
        let total: Int
        let caught: Int
        let unlocked: Bool
        let complete: Bool
    }
}

struct UnlockResponse: Codable {
    let ok: Bool
    let pokemon: PokemonInfo
    let generation: String?
    let generationComplete: Bool?
    let available: Int
    let caught: Int
    let total: Int
}
