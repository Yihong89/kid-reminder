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

/// 自定义听写表: a freeform, ungraded, repeatable word/phrase/sentence list the parent
/// or kid types in themselves (not drawn from vocab_words). `itemCount` is present on
/// the list endpoint but absent from the detail endpoint's nested `list`, hence optional.
struct DictationList: Codable, Identifiable {
    let id: Int
    let name: String
    let createdBy: String
    let createdAt: String
    let itemCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, itemCount
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}
struct DictationListsResponse: Codable { let lists: [DictationList] }

struct DictationListItem: Codable, Identifiable {
    let id: Int
    let seq: Int
    let text: String
}
struct DictationListDetail: Codable {
    let list: DictationList
    let items: [DictationListItem]
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

// MARK: - 科学 (PSLE Science open-ended)

/// PSLE awards one mark per distinct scoring point, so a Science question is never
/// simply right or wrong — it is graded point by point. Each point carries its
/// *kind*, which is what turns a miss into a diagnosis ("stopped at the
/// observation", "used an everyday word") rather than just a lost mark.
enum SciencePointKind: String, Codable {
    case observation, mechanism, keyword, data, comparison
    case variableIndependent = "variable_independent"
    case variableDependent = "variable_dependent"
    case variableControlled = "variable_controlled"
    case conclusion, aim, prediction, suggestion, definition, identification

    /// Plain-language label for the kid — "mechanism" means nothing to a 11-year-old.
    var label: String {
        switch self {
        case .observation: return "说出现象"
        case .mechanism: return "解释原理"
        case .keyword: return "科学名词"
        case .data: return "引用数据"
        case .comparison: return "两边都要说"
        case .variableIndependent: return "改变的变量"
        case .variableDependent: return "测量的变量"
        case .variableControlled: return "保持不变的变量"
        case .conclusion: return "写出结论"
        case .aim: return "实验目的"
        case .prediction: return "预测结果"
        case .suggestion: return "提出方法"
        case .definition: return "下定义"
        case .identification: return "答出名称"
        }
    }
}

/// `drawing` questions can't be answered by typing (e.g. "complete the circuit"),
/// so the practice view has to keep them out or mark them paper-only.
enum ScienceAnswerMode: String, Codable {
    case text, short, drawing
}

struct ScienceSessionItem: Codable, Identifiable {
    let itemId: Int
    let seq: Int
    let questionId: Int
    let theme: String
    let topic: String
    let questionType: String
    let answerMode: ScienceAnswerMode
    let marks: Int
    let context: String
    let prompt: String
    let image: String
    var id: Int { itemId }
}

struct ScienceSession: Codable {
    let sessionId: Int
    let items: [ScienceSessionItem]
}

/// An answer the paper's own mark scheme explicitly refuses, with the reason —
/// worth showing, since these are the near-misses that feel right.
struct ScienceDoNotAccept: Codable, Equatable {
    let answer: String
    let reason: String
}

struct ScienceMarkPointResult: Codable, Equatable, Identifiable {
    let markPointId: Int
    let seq: Int
    let pointKind: SciencePointKind
    let description: String
    let autoHit: Bool
    var id: Int { markPointId }
}

/// Deliberately carries `provisional` — the keyword verdict is a hint, and the
/// score only becomes real once a parent has reviewed it.
struct ScienceSubmitResult: Codable, Equatable {
    let autoScore: Int
    let marks: Int
    let modelAnswer: String
    let doNotAccept: [ScienceDoNotAccept]
    let provisional: Bool
    let points: [ScienceMarkPointResult]
}


// MARK: 科学 — papers + 错题本 (kid-facing browse screen)

/// One exam paper the kid can play through start to finish, in the paper's own
/// question order. `marksTotal`/`questionCount` count only non-drawing parts —
/// those are the ones a mark can actually be earned on from this screen.
struct SciencePaper: Codable, Identifiable {
    let paperKey: String
    let school: String
    let year: Int?
    let questionCount: Int
    let marksTotal: Int
    var id: String { paperKey }
}

/// `mistakeCount` rides along in the same response so the browse screen can
/// show/enable the 错题本 button without a second round trip.
struct SciencePapersResponse: Codable {
    let papers: [SciencePaper]
    let mistakeCount: Int
}
