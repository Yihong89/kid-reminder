import SwiftUI

enum ClassroomTab: String, CaseIterable, Identifiable {
    case homework = "作业"
    case materials = "资料"
    case announcements = "公告"
    var id: String { rawValue }
}

/// Google Classroom 面板：作业 / 资料 / 公告。
///
/// 作业有截止时间，按紧急程度分档；资料和公告没有截止时间，按课程（资料再按单元）
/// 分组，只做"方便翻到"这一件事。三条数据来自同一个 Apps Script Web App，
/// URL 和 Secret 在 设置 → Google Classroom 里填（存本机，不经过后端）。
struct ClassroomView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var classroom: ClassroomStore

    @State private var tab: ClassroomTab = .homework

    var body: some View {
        Group {
            if classroom.configured {
                content
            } else {
                setupPrompt
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await refresh()
            // 10 分钟自动刷一次。用 task 而不是独立 Timer，切走这个面板时随视图取消。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }

    private func refresh() async {
        await classroom.refresh(url: settings.classroomURL, secret: settings.classroomSecret)
    }

    // MARK: - 骨架

    private var content: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.6)
            ScrollView {
                switch tab {
                case .homework: homeworkBody
                case .materials: materialsBody
                case .announcements: announcementsBody
                }
            }
            Divider().opacity(0.6)
            footer
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(ClassroomTab.allCases) { t in
                    Text("\(t.rawValue) \(count(for: t))").tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 330)

            Spacer()

            searchField

            if classroom.isLoading { ProgressView().controlSize(.small) }

            Button {
                Task { await refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(classroom.isLoading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField("搜索标题 / 课程 / 单元", text: $classroom.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
            if classroom.isSearching {
                Button { classroom.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(classroom.isSearching ? 0.22 : 0.08), lineWidth: 1)
        )
        .frame(width: 215)
    }

    private func count(for tab: ClassroomTab) -> Int {
        switch tab {
        case .homework: return classroom.items.count
        case .materials: return classroom.materials.count
        case .announcements: return classroom.announcements.count
        }
    }

    // MARK: - 作业

    private var homeworkBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let detail = classroom.errorDetail {
                errorBanner(title: classroom.errorTitle ?? "出错了", detail: detail)
            }
            statsRow
            if classroom.grouped.isEmpty && !classroom.isLoading {
                if classroom.isSearching {
                    emptyState(emoji: "🔍", title: "没有匹配的作业", detail: "换个关键词试试。")
                } else {
                    emptyState(emoji: "🎉", title: "全部做完了", detail: "没有未完成的作业。")
                }
            } else {
                ForEach(classroom.grouped) { group in
                    homeworkSection(bucket: group.bucket, list: group.items)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statsRow: some View {
        let s = classroom.stats
        return HStack(spacing: 10) {
            statTile("\(s.overdue)", "已经逾期",
                     tint: ClassroomPalette.tint(.overdue), highlight: s.overdue > 0)
            statTile("\(s.week)", "这 7 天内要交",
                     tint: ClassroomPalette.tint(.today), highlight: false)
            statTile("\(s.total)", "未完成合计", tint: .secondary, highlight: false)
            if let c = classroom.counts?.courses {
                statTile("\(c)", "门在上的课", tint: .secondary, highlight: false)
            }
            Spacer()
        }
    }

    private func statTile(_ value: String, _ label: String, tint: Color, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(highlight ? tint : .primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 88, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(highlight ? tint.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func homeworkSection(bucket: HomeworkBucket, list: [ClassroomHomework]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                if bucket.collapsedByDefault { classroom.toggle(bucket) }
            } label: {
                bucketHeader(bucket: bucket, count: list.count,
                             collapsible: bucket.collapsedByDefault,
                             collapsed: classroom.isCollapsed(bucket),
                             tint: ClassroomPalette.tint(bucket), title: bucket.title)
            }
            .buttonStyle(.plain)

            if !classroom.isCollapsed(bucket) {
                ForEach(list) { item in
                    homeworkCard(item, bucket: bucket)
                }
            }
        }
    }

    private func homeworkCard(_ item: ClassroomHomework, bucket: HomeworkBucket) -> some View {
        let courseColor = classroom.color(for: item.course)
        let tint = ClassroomPalette.tint(bucket)

        return HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 2).fill(courseColor).frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.course)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(courseColor)
                        .lineLimit(1)
                    if let t = item.topic, !t.isEmpty {
                        Text("· \(t)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                metaLine(item)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 5) {
                if let due = item.due {
                    Text(ClassroomFmt.countdown(to: due, from: classroom.now))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint.opacity(0.12)))
                }
                if let url = item.linkURL {
                    Link(destination: url) {
                        Text("打开 Classroom").font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(bucket == .overdue ? tint.opacity(0.32) : Color.primary.opacity(0.06),
                              lineWidth: 1)
        )
    }

    private func metaLine(_ item: ClassroomHomework) -> some View {
        var parts: [String] = ["截止 \(ClassroomFmt.dueText(item))"]
        if let p = ClassroomFmt.points(item.points) { parts.append(p) }
        if let k = item.kind, !k.isEmpty { parts.append(k) }
        if let s = item.stateLabel { parts.append(s) }
        if item.late == true { parts.append("已逾期") }

        return Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - 资料

    private var materialsBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let detail = classroom.errorDetail {
                errorBanner(title: classroom.errorTitle ?? "出错了", detail: detail)
            }
            if classroom.materialGroups.isEmpty && !classroom.isLoading {
                if classroom.isSearching {
                    emptyState(emoji: "🔍", title: "没有匹配的资料", detail: "换个关键词试试。")
                } else {
                    emptyState(emoji: "📁", title: "没有资料",
                               detail: "老师还没在 Classwork 里发过 Materials。")
                }
            } else {
                ForEach(classroom.materialGroups) { group in
                    VStack(alignment: .leading, spacing: 9) {
                        Button { classroom.toggleCourse(group.course) } label: {
                            courseHeader(group.course, count: group.count,
                                         expanded: classroom.isCourseExpanded(group.course))
                        }
                        .buttonStyle(.plain)

                        if classroom.isCourseExpanded(group.course) {
                            ForEach(group.topics) { topic in
                                VStack(alignment: .leading, spacing: 5) {
                                    Button {
                                        classroom.toggleUnit(group.course, topic.topic)
                                    } label: {
                                        unitHeader(topic.displayName, count: topic.items.count,
                                                   expanded: classroom.isUnitExpanded(group.course, topic.topic))
                                    }
                                    .buttonStyle(.plain)

                                    if classroom.isUnitExpanded(group.course, topic.topic) {
                                        ForEach(topic.items) { m in
                                            materialRow(m)
                                        }
                                    }
                                }
                                .padding(.leading, 11)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func materialRow(_ m: ClassroomMaterial) -> some View {
        HStack(spacing: 9) {
            Image(systemName: materialIcon(m.kind))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 15)
            Text(m.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let url = m.linkURL {
                Link(destination: url) {
                    Text("打开").font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Text("无链接").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    /// 老师用强调色，同学和我用中性色——目的是让人一眼扫过时先看老师发的。
    private func authorTint(_ author: String?) -> Color {
        switch author ?? "" {
        case "teacher": return Color(red: 0.20, green: 0.45, blue: 0.90)
        case "me": return Color(red: 0.20, green: 0.60, blue: 0.40)
        default: return .secondary
        }
    }

    private func materialIcon(_ kind: String?) -> String {
        switch kind {
        case "video": return "play.rectangle.fill"
        case "link": return "link"
        case "form": return "list.bullet.rectangle"
        case "drive": return "doc.fill"
        default: return "doc.text"
        }
    }

    // MARK: - 公告

    private var announcementsBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let detail = classroom.errorDetail {
                errorBanner(title: classroom.errorTitle ?? "出错了", detail: detail)
            }
            if classroom.announcementGroups.isEmpty && !classroom.isLoading {
                if classroom.isSearching {
                    emptyState(emoji: "🔍", title: "没有匹配的公告", detail: "换个关键词试试。")
                } else {
                    emptyState(emoji: "📣", title: "没有公告",
                               detail: "老师还没在 Stream 里发过东西。")
                }
            } else {
                ForEach(classroom.announcementGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { classroom.toggleCourse(group.course) } label: {
                            courseHeader(group.course, count: group.count,
                                         expanded: classroom.isCourseExpanded(group.course))
                        }
                        .buttonStyle(.plain)

                        if classroom.isCourseExpanded(group.course) {
                            // 只有一种作者时不显示子标题——"老师 3"下面再列三条，
                            // 这层分组没有任何信息量。
                            if group.authors.count <= 1 {
                                ForEach(group.authors.first?.items ?? []) { a in
                                    announcementCard(a)
                                }
                            } else {
                                ForEach(group.authors) { ag in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Button {
                                            classroom.toggleAuthor(group.course, ag.key)
                                        } label: {
                                            unitHeader(ag.title, count: ag.items.count,
                                                       expanded: classroom.isAuthorExpanded(group.course, ag.key))
                                        }
                                        .buttonStyle(.plain)

                                        if classroom.isAuthorExpanded(group.course, ag.key) {
                                            ForEach(ag.items) { a in
                                                announcementCard(a)
                                            }
                                        }
                                    }
                                    .padding(.leading, 11)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func announcementCard(_ a: ClassroomAnnouncement) -> some View {
        let courseColor = classroom.color(for: a.course ?? "")
        return HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 2)
                .fill(courseColor.opacity(0.75))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(a.body)
                    .font(.system(size: 12.5))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let who = a.authorLabel {
                        Text(who)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(authorTint(a.author))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(authorTint(a.author).opacity(0.13)))
                    }
                    Text(ClassroomFmt.ago(a.created, from: classroom.now))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if let url = a.linkURL {
                        Link(destination: url) {
                            Text("在 Classroom 打开").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - 共用

    private func courseHeader(_ course: String, count: Int, expanded: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 9)
            Circle()
                .fill(classroom.color(for: course))
                .frame(width: 7, height: 7)
            Text(course)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func unitHeader(_ title: String, count: Int, expanded: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 8)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }

    private func bucketHeader(bucket: HomeworkBucket, count: Int, collapsible: Bool,
                              collapsed: Bool, tint: Color, title: String) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3, height: 13)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if collapsible {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func emptyState(emoji: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(emoji).font(.system(size: 34))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var setupPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "graduationcap")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("还没连上 Google Classroom")
                .font(.system(size: 15, weight: .semibold))
            VStack(spacing: 4) {
                Text("到 **设置 → Google Classroom** 里填入")
                Text("Web App URL 和 Secret，就能看到作业了。")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func errorBanner(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ClassroomPalette.tint(.overdue))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("下面显示的是上一次成功拿到的数据。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                classroom.errorTitle = nil
                classroom.errorDetail = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(ClassroomPalette.tint(.overdue).opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(ClassroomPalette.tint(.overdue).opacity(0.3), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(ClassroomFmt.updated(classroom.lastUpdated, from: classroom.now))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if let email = classroom.email, !email.isEmpty {
                Text("· \(email)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("每 10 分钟自动刷新")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
    }
}
