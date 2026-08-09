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

    enum CodingKeys: String, CodingKey {
        case id, title, emoji, done, minutes, targetDate, countdownEnabled, countdownStart, daysLeft, createdBy
        case repeatType = "repeat"
    }

    /// Human-friendly countdown label, mirroring the web panel.
    var countdownText: String? {
        guard countdownEnabled, let d = daysLeft else { return nil }
        if d < 0 { return "⏰ \(-d)d ago" }
        if d == 0 { return "📅 Today!" }
        if d <= countdownStart { return "⏳ \(d)d" }
        return "📅 in \(d)d"
    }
}

struct TasksResponse: Codable {
    let today: String
    let date: String
    let tasks: [KidTask]
}

/// Curated emoji choices for the add-task form (matches the web panel).
let EmojiChoices: [(String, String)] = [
    ("", "none"), ("🦷", "brush teeth"), ("🪥", "teeth"), ("🛁", "bath"), ("🧼", "wash"),
    ("📚", "homework"), ("✏️", "write"), ("📖", "read"), ("🎨", "art"), ("🎹", "piano"), ("🎸", "guitar"),
    ("💧", "water"), ("🍎", "fruit"), ("🥦", "veg"), ("🍽️", "meals"), ("🍵", "tea"),
    ("🛏️", "bed"), ("🌅", "morning"), ("🌙", "night"), ("😴", "sleep"), ("☀️", "day"),
    ("🎒", "school"), ("🏃", "run"), ("⚽", "football"), ("🏀", "ball"), ("💪", "workout"),
    ("🧹", "chores"), ("🧺", "laundry"), ("🐶", "dog"), ("🪴", "plant"), ("🧠", "focus"), ("⭐", "star"),
]
