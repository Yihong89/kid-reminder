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

    private var clock: Timer?

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

    private func rebuildColors() {
        let names = Set(items.map(\.course)).sorted()
        var map: [String: Color] = [:]
        for (i, name) in names.enumerated() {
            map[name] = ClassroomPalette.colors[i % ClassroomPalette.colors.count]
        }
        courseColors = map
    }

    func color(for course: String) -> Color {
        courseColors[course] ?? ClassroomPalette.colors[0]
    }

    var grouped: [HomeworkGroup] {
        var map: [HomeworkBucket: [ClassroomHomework]] = [:]
        for item in items {
            map[HomeworkBucketRules.bucket(for: item.due, now: now), default: []].append(item)
        }
        return HomeworkBucket.allCases.compactMap { bucket in
            guard let list = map[bucket], !list.isEmpty else { return nil }
            let sorted = list.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            return HomeworkGroup(bucket: bucket, items: sorted)
        }
    }

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
}
