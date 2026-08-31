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

// MARK: - Dictation (听写)

struct DictationItemRef: Codable, Identifiable {
    let seq: Int
    let wordId: Int
    var id: Int { wordId }
}

struct DictationSession: Codable {
    let sessionId: Int
    let items: [DictationItemRef]
}

/// One row of /api/dictation/sessions — history list (used by DictationHistoryView so
/// the kid can review their own graded results, and by the web admin's grading queue).
/// Also doubles as the `session` field of /api/dictation/sessions/:id, which is a plain
/// `SELECT *` on dictation_sessions and so doesn't carry itemCount/correctCount/
/// incorrectCount — hence those being optional even though the list endpoint always
/// sends them.
struct DictationSessionSummary: Codable, Identifiable {
    let id: Int
    let status: String // "in_progress" | "pending_grading" | "graded"
    let createdAt: String
    let completedAt: String?
    let gradedAt: String?
    let itemCount: Int?
    let correctCount: Int?
    let incorrectCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, itemCount, correctCount, incorrectCount
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case gradedAt = "graded_at"
    }
}
struct DictationSessionListResponse: Codable { let sessions: [DictationSessionSummary] }

/// One graded word within a session's detail — the actual per-word ✓/✗ the kid reviews.
struct DictationSessionDetailItem: Codable, Identifiable {
    let id: Int
    let seq: Int
    let result: String? // nil until graded; "correct" | "incorrect" once it is
    let wordId: Int
    let character: String
    let word: String
    let pinyin: String
    let sentence: String
    let level: String
    let lesson: String

    enum CodingKeys: String, CodingKey {
        case id, seq, result, character, word, pinyin, sentence, level, lesson
        case wordId = "word_id"
    }
}
struct DictationSessionDetail: Codable {
    let session: DictationSessionSummary
    let items: [DictationSessionDetailItem]
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

// MARK: - English wrong-answer practice (英语错题)

enum EnglishQuestionType: String, Codable {
    case fillBlank = "fill_blank"
    case mcq
    case sentenceTransform = "sentence_transform"
}

struct EnglishSessionItem: Codable, Identifiable {
    let itemId: Int
    let seq: Int
    let questionId: Int
    let type: EnglishQuestionType
    let topic: String
    let prompt: String
    let options: [String]?
    let needsAudio: Bool
    var id: Int { itemId }
}

struct EnglishSession: Codable {
    let sessionId: Int
    let items: [EnglishSessionItem]
}

struct EnglishAnswerResult: Codable, Equatable {
    let correct: Bool
    let correctAnswer: String
    let explanation: String
}
