import SwiftUI

/// Google Classroom 作业面板。
///
/// 只显示**还没交**的作业，按紧急程度分档。数据来自孩子自己账号部署的 Apps Script Web App，
/// URL 和 Secret 在 设置 → Google Classroom 里填（存在本机 UserDefaults，不经过服务器）。
struct ClassroomView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var classroom: ClassroomStore

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
            // 10 分钟自动刷一次。用 task 而不是独立 Timer，是为了在切走这个面板时
            // 随视图一起取消，不会留着后台循环。
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

    // MARK: - 主面板

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let detail = classroom.errorDetail {
                        errorBanner(title: classroom.errorTitle ?? "出错了", detail: detail)
                    }
                    if classroom.grouped.isEmpty && !classroom.isLoading {
                        emptyState
                    } else {
                        ForEach(classroom.grouped) { group in
                            section(bucket: group.bucket, list: group.items)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.6)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            let s = classroom.stats
            statTile("\(s.overdue)", "已经逾期", tint: ClassroomPalette.tint(.overdue), highlight: s.overdue > 0)
            statTile("\(s.week)", "这 7 天内要交", tint: ClassroomPalette.tint(.today), highlight: false)
            statTile("\(s.total)", "未完成合计", tint: .secondary, highlight: false)
            if let c = classroom.counts?.courses {
                statTile("\(c)", "门在上的课", tint: .secondary, highlight: false)
            }

            Spacer()

            if classroom.isLoading { ProgressView().controlSize(.small) }

            Button {
                Task { await refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(classroom.isLoading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
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

    // MARK: - 分档

    @ViewBuilder
    private func section(bucket: HomeworkBucket, list: [ClassroomHomework]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                if bucket.collapsedByDefault { classroom.toggle(bucket) }
            } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ClassroomPalette.tint(bucket))
                        .frame(width: 3, height: 13)
                    Text(bucket.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("\(list.count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if bucket.collapsedByDefault {
                        Image(systemName: classroom.isCollapsed(bucket) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !classroom.isCollapsed(bucket) {
                ForEach(list) { item in
                    card(item, bucket: bucket)
                }
            }
        }
    }

    private func card(_ item: ClassroomHomework, bucket: HomeworkBucket) -> some View {
        let courseColor = classroom.color(for: item.course)
        let tint = ClassroomPalette.tint(bucket)

        return HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 2)
                .fill(courseColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.course)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(courseColor)
                    .lineLimit(1)

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

    // MARK: - 状态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("🎉").font(.system(size: 34))
            Text("全部做完了").font(.system(size: 15, weight: .semibold))
            Text("没有未完成的作业。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
