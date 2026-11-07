import Foundation

// Google Classroom 作业看板 —— 数据模型
//
// 数据来自孩子自己账号部署的 Apps Script Web App（见 classroom-homework/probe/appsscript）。
// 这里刻意不碰 Google OAuth：app 只拉一段 JSON，孩子的授权只发生在 script.google.com 那一次。
// 好处是学校的「未满 18 岁禁止第三方 App」策略管不到，令牌过期也跟 app 无关。

struct ClassroomPayload: Decodable {
    let ok: Bool
    let schema: Int?
    let generated_at: String?
    let email: String?
    let counts: ClassroomCounts?
    let courses: [ClassroomCourse]?
    let items: [ClassroomHomework]?
    let done: [ClassroomDone]?
    let materials: [ClassroomMaterial]?
    let announcements: [ClassroomAnnouncement]?

    // 失败时才有
    let error: String?
    let code: Int?
    let hint: String?
    let message: String?
}

struct ClassroomCounts: Decodable {
    let courses: Int?
    let coursework: Int?
    let submissions: Int?
    let open: Int?
}

struct ClassroomCourse: Decodable {
    let id: String?
    let name: String?
    let open: Int?
}

struct ClassroomHomework: Decodable, Identifiable {
    let course: String
    let course_id: String?
    let title: String
    /// 老师挂的单元/主题名。空字符串表示"未分类"。
    let topic: String?
    let due_epoch: Double?
    let due_label: String?
    let has_time: Bool?
    let state: String?
    let late: Bool?
    let points: Double?
    let kind: String?
    let link: String?

    /// 稳定 id：同一份作业在多次刷新之间不能变，否则展开状态会丢。
    var id: String { "\(course_id ?? course)|\(title)|\(Int(due_epoch ?? 0))" }

    var due: Date? {
        guard let due_epoch else { return nil }
        return Date(timeIntervalSince1970: due_epoch / 1000.0)
    }

    var linkURL: URL? {
        guard let link, !link.isEmpty, let u = URL(string: link) else { return nil }
        return u
    }

    /// 只有 TURNED_IN / RETURNED 算做完。RECLAIMED_BY_STUDENT 是"自己撤回了提交"，
    /// 语义上属于没交，必须算未完成——这是最容易写错的一处。
    var stateLabel: String? {
        switch state {
        case "NEW": return "还没打开过"
        case "CREATED": return "没提交"
        case "RECLAIMED_BY_STUDENT": return "撤回提交了"
        default: return nil
        }
    }
}

// MARK: - 已交 / 已批改

struct ClassroomDone: Decodable, Identifiable {
    let course: String?
    let course_id: String?
    let title: String?
    let topic: String?
    /// "TURNED_IN"（已交、等批）或 "RETURNED"（已批改返还）
    let state: String?
    let points: Double?
    let max_points: Double?
    let late: Bool?
    let due_label: String?
    let due_epoch: Double?
    let updated_epoch: Double?
    let link: String?

    var id: String { "\(course_id ?? "")|\(title ?? "")|\(Int(due_epoch ?? 0))" }
    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(无标题)" : t
    }
    var topicName: String { (topic ?? "").trimmingCharacters(in: .whitespaces) }
    var isReturned: Bool { state == "RETURNED" }
    var statusLabel: String { isReturned ? "已批改" : "已交" }

    /// "85 / 100"。没有分数就返回 nil，不显示 0 分。
    var gradeText: String? {
        guard let p = points else { return nil }
        let g = ClassroomDone.num(p)
        if let m = max_points, m > 0 { return "\(g) / \(ClassroomDone.num(m))" }
        return g
    }

    var updated: Date? {
        guard let updated_epoch else { return nil }
        return Date(timeIntervalSince1970: updated_epoch / 1000.0)
    }
    var due: Date? {
        guard let due_epoch else { return nil }
        return Date(timeIntervalSince1970: due_epoch / 1000.0)
    }
    var linkURL: URL? {
        guard let link, !link.isEmpty, let u = URL(string: link) else { return nil }
        return u
    }

    static func num(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - 资料（Classwork → Materials）

struct ClassroomMaterial: Decodable, Identifiable {
    let course: String?
    let course_id: String?
    let title: String?
    let topic: String?
    let kind: String?
    let created_epoch: Double?
    let link: String?

    var id: String { "\(course_id ?? "")|\(title ?? "")|\(Int(created_epoch ?? 0))" }
    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(无标题)" : t
    }
    var topicName: String { (topic ?? "").trimmingCharacters(in: .whitespaces) }
    var created: Date? {
        guard let created_epoch else { return nil }
        return Date(timeIntervalSince1970: created_epoch / 1000.0)
    }
    var linkURL: URL? {
        guard let link, !link.isEmpty, let u = URL(string: link) else { return nil }
        return u
    }
}

// MARK: - 公告（Stream）

struct ClassroomAnnouncement: Decodable, Identifiable {
    let course: String?
    let course_id: String?
    /// "teacher" / "student" / "me"。空字符串表示判不出来。
    let author: String?
    /// 发布人真名。要 classroom.profile.emails 权限，学校域拒绝时是空串。
    let creator: String?
    let text: String?
    let kind: String?
    let created_epoch: Double?
    let link: String?

    var id: String { "\(course_id ?? "")|\(Int(created_epoch ?? 0))|\((text ?? "").count)" }
    var body: String {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(只有附件，没有正文)" : t
    }
    var created: Date? {
        guard let created_epoch else { return nil }
        return Date(timeIntervalSince1970: created_epoch / 1000.0)
    }
    var linkURL: URL? {
        guard let link, !link.isEmpty, let u = URL(string: link) else { return nil }
        return u
    }

    var creatorName: String? {
        let n = (creator ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    /// 谁发的。老师 vs 同学是靠"只有老师能建作业/资料"反推的，不是 API 直接给的。
    var authorLabel: String? {
        switch author ?? "" {
        case "teacher": return "老师"
        case "student": return "同学"
        case "me": return "我"
        default: return nil
        }
    }
}

enum HomeworkBucket: Int, CaseIterable, Identifiable {
    case overdue      // 逾期，但还"新鲜"
    case today        // 今天必须做
    case tomorrow
    case soon         // 这周内
    case later
    case stale        // 逾期太久，默认折叠
    case noDue        // 没有截止日期，默认折叠

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue: return "已经逾期"
        case .today: return "今天必须做"
        case .tomorrow: return "明天截止"
        case .soon: return "这周内"
        case .later: return "以后"
        case .stale: return "很久以前就逾期了"
        case .noDue: return "没有截止日期"
        }
    }

    /// 真实数据里有一批两个月前的作业还挂在"未完成"，也有老师随手发的、
    /// 永远不过期的材料。这两类如果和今天要交的混在一起，红色就失去意义了，
    /// 孩子两周内就会学会无视整个看板。所以默认收起来，想看再点开。
    var collapsedByDefault: Bool { self == .stale || self == .noDue }
}

enum HomeworkBucketRules {
    /// 逾期超过这么多天，挪进"很久以前"。
    static let staleAfterDays = 28

    /// 未来这么多小时内到期，不管日历上是不是明天，都算"今天必须做"。
    /// 凌晨 02:20 截止的作业，日历上是明天，但孩子今晚就得写完。
    static let urgentWindow: TimeInterval = 10 * 3600

    static func bucket(for due: Date?, now: Date, calendar: Calendar = .current) -> HomeworkBucket {
        guard let due else { return .noDue }

        if due < now.addingTimeInterval(-Double(staleAfterDays) * 86400) { return .stale }
        if due < now { return .overdue }
        if due.timeIntervalSince(now) < urgentWindow { return .today }
        if calendar.isDate(due, inSameDayAs: now) { return .today }

        if let tomorrow = calendar.date(byAdding: .day, value: 1,
                                        to: calendar.startOfDay(for: now)),
           calendar.isDate(due, inSameDayAs: tomorrow) {
            return .tomorrow
        }
        if due < now.addingTimeInterval(7 * 86400) { return .soon }
        return .later
    }
}

enum ClassroomFmt {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    /// 服务端已经给了 due_label（按课程时区算好的），优先用它。
    static func dueText(_ item: ClassroomHomework) -> String {
        if let label = item.due_label, !label.isEmpty { return label }
        guard let due = item.due else { return "没有截止日期" }
        return (item.has_time ?? false) ? clock.string(from: due) : dateOnly.string(from: due)
    }

    static func countdown(to due: Date, from now: Date) -> String {
        let delta = due.timeIntervalSince(now)
        let late = delta < 0
        let s = abs(delta)
        let days = Int(s / 86400), hours = Int(s / 3600), mins = Int(s / 60)

        var span = ""
        if days >= 1 { span = "\(days) 天" }
        else if hours >= 1 { span = "\(hours) 小时" }
        else if mins >= 1 { span = "\(mins) 分钟" }

        if late { return span.isEmpty ? "刚刚逾期" : "逾期 \(span)" }
        return span.isEmpty ? "即将截止" : "还剩 \(span)"
    }

    static func points(_ p: Double?) -> String? {
        guard let p, p > 0 else { return nil }
        return p == p.rounded() ? "\(Int(p)) 分" : String(format: "%.1f 分", p)
    }

    /// "3 天前" / "2 小时前" —— 公告和资料没有截止时间，只能显示发布距今多久
    static func ago(_ date: Date?, from now: Date) -> String {
        guard let date else { return "" }
        let d = now.timeIntervalSince(date)
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        if d < 86400 * 30 { return "\(Int(d / 86400)) 天前" }
        return dateOnly.string(from: date)
    }

    static func updated(_ date: Date?, from now: Date) -> String {
        guard let date else { return "还没更新过" }
        let d = now.timeIntervalSince(date)
        if d < 45 { return "刚刚更新" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前更新" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前更新" }
        return "\(Int(d / 86400)) 天前更新"
    }
}
