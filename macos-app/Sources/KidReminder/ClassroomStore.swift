import Foundation
import SwiftUI

/// 课程配色。
///
/// 不用哈希：8 门课塞 8 个颜色，随你怎么哈希都会撞，撞了就只能靠读标题区分。
/// 改成"按当前出现过的课程名排序后顺序分配"，≤8 门课时保证零碰撞。
enum ClassroomPalette {
    static let colors: [Color] = [
        Color(red: 0.30, green: 0.45, blue: 0.95),
        Color(red: 0.90, green: 0.45, blue: 0.20),
        Color(red: 0.18, green: 0.68, blue: 0.45),
        Color(red: 0.72, green: 0.38, blue: 0.85),
        Color(red: 0.16, green: 0.62, blue: 0.78),
        Color(red: 0.88, green: 0.36, blue: 0.52),
        Color(red: 0.85, green: 0.66, blue: 0.16),
        Color(red: 0.42, green: 0.52, blue: 0.66),
    ]

    static func tint(_ bucket: HomeworkBucket) -> Color {
        switch bucket {
        case .overdue: return Color(red: 0.85, green: 0.20, blue: 0.18)
        case .today: return Color(red: 0.92, green: 0.45, blue: 0.10)
        case .tomorrow: return Color(red: 0.80, green: 0.62, blue: 0.10)
        case .soon: return Color(red: 0.20, green: 0.52, blue: 0.78)
        case .later: return Color(red: 0.45, green: 0.50, blue: 0.58)
        case .stale: return Color(red: 0.56, green: 0.44, blue: 0.40)
        case .noDue: return Color(red: 0.55, green: 0.55, blue: 0.60)
        }
    }
}

struct HomeworkGroup: Identifiable {
    let bucket: HomeworkBucket
    let items: [ClassroomHomework]
    var id: Int { bucket.rawValue }
}

@MainActor
final class ClassroomStore: ObservableObject {
    @Published private(set) var items: [ClassroomHomework] = []
    @Published private(set) var materials: [ClassroomMaterial] = []
    @Published private(set) var announcements: [ClassroomAnnouncement] = []
    @Published private(set) var email: String?
    @Published private(set) var counts: ClassroomCounts?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var configured = false
    @Published private(set) var now = Date()
    @Published private(set) var courseColors: [String: Color] = [:]

    @Published var errorTitle: String?
    @Published var errorDetail: String?
    @Published var collapsed: Set<HomeworkBucket> =
        Set(HomeworkBucket.allCases.filter { $0.collapsedByDefault })

    // MARK: - 搜索与折叠
    //
    // 资料动辄上百条（真实数据里 EL 一门课就有 109 份 coursework），平铺出来
    // 根本没法用。所以两级折叠 + 搜索：
    //   · 课程默认收起，点开才看到单元
    //   · 单元也默认收起，点开才看到条目
    //   · 一旦开始搜索，所有分组强制展开，否则搜到了却看不见
    @Published var searchText: String = ""
    @Published private(set) var expandedCourses: Set<String> = []
    @Published private(set) var expandedUnits: Set<String> = []

    private var clock: Timer?

    // MARK: - 生命周期

    func startClock() {
        clock?.invalidate()
        // 倒计时文本要自己走，否则"还剩 3 小时"会一直停在打开那一刻
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    func refresh(url: String, secret: String) async {
        guard !isLoading else { return }

        let client = ClassroomClient(baseURL: url, secret: secret)
        configured = client.isConfigured

        guard client.isConfigured else {
            items = []
            materials = []
            announcements = []
            email = nil
            counts = nil
            lastUpdated = nil
            errorTitle = nil
            errorDetail = nil
            courseColors = [:]
            return
        }

        isLoading = true
        now = Date()
        defer { isLoading = false }

        do {
            let payload = try await client.fetch()
            items = payload.items ?? []
            materials = payload.materials ?? []
            announcements = payload.announcements ?? []
            email = payload.email
            counts = payload.counts
            lastUpdated = Date()
            errorTitle = nil
            errorDetail = nil
            rebuildColors()
        } catch {
            // 关键：取数失败时**保留上一次的数据**。一次网络抖动就把面板清空、
            // 显示成"今天没作业"，比显示过期数据糟糕得多。
            errorTitle = "刷新失败"
            errorDetail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - 配色

    private func rebuildColors() {
        var all = Set(items.map(\.course))
        all.formUnion(materials.compactMap { $0.course })
        all.formUnion(announcements.compactMap { $0.course })
        let names = all.sorted()
        var map: [String: Color] = [:]
        for (i, name) in names.enumerated() {
            map[name] = ClassroomPalette.colors[i % ClassroomPalette.colors.count]
        }
        courseColors = map
    }

    func color(for course: String) -> Color {
        courseColors[course] ?? ClassroomPalette.colors[0]
    }

    // MARK: - 搜索与折叠的接口

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isSearching: Bool { !query.isEmpty }

    private func hits(_ fields: [String?]) -> Bool {
        guard isSearching else { return true }
        for f in fields {
            if let f, f.lowercased().contains(query) { return true }
        }
        return false
    }

    func toggleCourse(_ course: String) {
        if expandedCourses.contains(course) {
            expandedCourses.remove(course)
        } else {
            expandedCourses.insert(course)
        }
    }

    func toggleUnit(_ course: String, _ unit: String) {
        let key = course + "|" + unit
        if expandedUnits.contains(key) { expandedUnits.remove(key) } else { expandedUnits.insert(key) }
    }

    /// 搜索时一律展开——搜到了却藏在折叠里等于没搜。
    func isCourseExpanded(_ course: String) -> Bool {
        isSearching || expandedCourses.contains(course)
    }

    func isUnitExpanded(_ course: String, _ unit: String) -> Bool {
        isSearching || expandedUnits.contains(course + "|" + unit)
    }

    // MARK: - 作业

    var grouped: [HomeworkGroup] {
        var map: [HomeworkBucket: [ClassroomHomework]] = [:]
        for item in items where hits([item.title, item.course, item.topic]) {
            map[HomeworkBucketRules.bucket(for: item.due, now: now), default: []].append(item)
        }
        return HomeworkBucket.allCases.compactMap { bucket in
            guard let list = map[bucket], !list.isEmpty else { return nil }
            let sorted = list.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            return HomeworkGroup(bucket: bucket, items: sorted)
        }
    }

    /// 统计数字始终按全量算，不跟着搜索变——否则"已经逾期 0"会误导人。
    var stats: (overdue: Int, week: Int, total: Int) {
        var overdue = 0, week = 0
        for item in items {
            switch HomeworkBucketRules.bucket(for: item.due, now: now) {
            case .overdue: overdue += 1
            case .today, .tomorrow, .soon: week += 1
            default: break
            }
        }
        return (overdue, week, items.count)
    }

    func toggle(_ bucket: HomeworkBucket) {
        if collapsed.contains(bucket) { collapsed.remove(bucket) } else { collapsed.insert(bucket) }
    }

    func isCollapsed(_ bucket: HomeworkBucket) -> Bool { collapsed.contains(bucket) }

    // MARK: - 资料

    var materialGroups: [MaterialCourseGroup] {
        var byCourse: [String: [ClassroomMaterial]] = [:]
        for m in materials where hits([m.title, m.course, m.topic]) {
            byCourse[m.course ?? "(未知课程)", default: []].append(m)
        }
        return byCourse.keys.sorted().map { course in
            var byTopic: [String: [ClassroomMaterial]] = [:]
            for m in byCourse[course]! {
                byTopic[m.topicName, default: []].append(m)
            }
            // 有名字的单元按名字排，"未分类"永远垫底
            let topics = byTopic.keys.sorted { a, b in
                if a.isEmpty != b.isEmpty { return !a.isEmpty }
                return a.localizedStandardCompare(b) == .orderedAscending
            }.map { topic in
                MaterialTopicGroup(
                    topic: topic,
                    items: byTopic[topic]!.sorted {
                        ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
                    }
                )
            }
            return MaterialCourseGroup(course: course, topics: topics,
                                       count: byCourse[course]!.count)
        }
    }

    // MARK: - 公告

    var announcementGroups: [AnnouncementCourseGroup] {
        var byCourse: [String: [ClassroomAnnouncement]] = [:]
        for a in announcements where hits([a.text, a.course]) {
            byCourse[a.course ?? "(未知课程)", default: []].append(a)
        }
        return byCourse.keys.sorted().map { course in
            AnnouncementCourseGroup(
                course: course,
                items: byCourse[course]!.sorted {
                    ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
                }
            )
        }
    }
}

struct MaterialTopicGroup: Identifiable {
    let topic: String
    let items: [ClassroomMaterial]
    var id: String { topic }
    var displayName: String { topic.isEmpty ? "未分类" : topic }
}

struct MaterialCourseGroup: Identifiable {
    let course: String
    let topics: [MaterialTopicGroup]
    let count: Int
    var id: String { course }
}

struct AnnouncementCourseGroup: Identifiable {
    let course: String
    let items: [ClassroomAnnouncement]
    var id: String { course }
}
