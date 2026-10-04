import AppKit
import LuluCore
import SwiftUI

/// v0.4「记录」tab data: pages of HistoryStore, newest at the bottom.
final class HistoryModel: ObservableObject {
    static let pageSize = 200
    /// Hidden `--demo-history-day N`: after opening, scroll so the separator of N days ago is at the top.
    nonisolated(unsafe) static var demoScrollToDaysAgo: Int?

    let source: ComposeWindow.HistorySource
    let thumbnails: [String: NSImage]
    let labels: [String: String]
    @Published private(set) var messages: [Message] = []
    @Published private(set) var hasMore = false
    @Published private(set) var loaded = false
    /// Row to keep in view after loading an older page.
    @Published var anchor: String?

    init(source: ComposeWindow.HistorySource, thumbnails: [String: NSImage], labels: [String: String]) {
        self.source = source
        self.thumbnails = thumbnails
        self.labels = labels
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        let page = source.store.page(limit: Self.pageSize)
        messages = page.messages
        hasMore = page.hasMore
        loaded = true
        NSLog("[lulu] history tab: %ld of %ld messages loaded (more: %@)", page.messages.count, source.store.count, page.hasMore ? "yes" : "no")
    }

    func loadOlder() {
        guard hasMore, let first = messages.first else { return }
        let page = source.store.page(limit: Self.pageSize, before: first)
        anchor = first.id
        messages = page.messages + messages
        hasMore = page.hasMore
    }

    var rows: [HistoryTimeline.Row] { HistoryTimeline.rows(messages, dndSpans: source.dndSpans, complete: !hasMore) }
}

struct HistoryPane: View {
    @ObservedObject var model: HistoryModel
    let partnerName: String

    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)
    private static let listHeight: CGFloat = 330

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let away = model.source.away { awayCard(away) }
            list
        }
        .onAppear { model.loadIfNeeded() }
    }

    private func awayCard(_ s: AwaySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.source.awayTitle)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Self.accent)
            FlowLayout(spacing: 10, lineSpacing: 3) {
                ForEach(model.source.awaySincerity ? s.sincerityLines : s.lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color(white: 0.3))
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Self.accent.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Self.accent.opacity(0.3), lineWidth: 1))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) {
                    if model.hasMore {
                        Button { model.loadOlder() } label: {
                            Text("更早的 ↑")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Self.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white).padding(1).background(Capsule().fill(Self.accent.opacity(0.4))))
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                    if model.loaded && model.messages.isEmpty {
                        Text("还没有记录，给\(partnerName)发第一条吧～")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.top, 120)
                    }
                    ForEach(model.rows) { row in
                        switch row {
                        case .day(let label, _): daySeparator(label).id(row.id)
                        case .message(let m): messageRow(m).id(row.id)
                        case .dnd(let label, _): dndDivider(label).id(row.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.trailing, 6)
                .padding(.vertical, 4)
            }
            .frame(height: Self.listHeight)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.55)))
            .onAppear {
                model.loadIfNeeded()
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                if let n = HistoryModel.demoScrollToDaysAgo, let d = Calendar.current.date(byAdding: .day, value: -n, to: Date()) {
                    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo("day-\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)", anchor: .top)
                    }
                }
            }
            .onChange(of: model.anchor) { _, id in
                guard let id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private func daySeparator(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(white: 0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(white: 0.9)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    /// v0.8: where a 勿扰 stretch began: "😤 勿扰中 14:05–15:10" between two thin lines.
    private func dndDivider(_ label: String) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color(red: 0.55, green: 0.55, blue: 0.75).opacity(0.35)).frame(height: 1)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.38, green: 0.38, blue: 0.6))
                .fixedSize()
            Rectangle().fill(Color(red: 0.55, green: 0.55, blue: 0.75).opacity(0.35)).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func messageRow(_ m: Message) -> some View {
        let mine = m.from == model.source.me
        HStack(alignment: .bottom, spacing: 4) {
            if mine {
                Spacer(minLength: 40)
                time(m)
                content(m, mine: mine)
            } else {
                content(m, mine: mine)
                time(m)
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 6)
    }

    private func time(_ m: Message) -> some View {
        Text(HistoryTimeline.timeLabel(m.ts))
            .font(.system(size: 9, design: .rounded))
            .foregroundStyle(Color(white: 0.6))
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func content(_ m: Message, mine: Bool) -> some View {
        switch m.kind {
        case .sticker:
            let id = m.stickerId ?? ""
            VStack(spacing: 2) {
                if let img = model.thumbnails[id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 76, maxHeight: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("🧸").font(.system(size: 30))
                }
                Text(model.labels[id] ?? "表情")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.45))
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 12).fill(mine ? Self.accent.opacity(0.14) : Color.white))
        case .poke:
            chip("❤️", mine ? "送出一颗爱心" : "\(partnerName)送来一颗爱心", mine: mine)
        case .visit:
            chip("🏃", mine ? "去找\(partnerName)玩" : "\(partnerName)来找你玩", mine: mine)
        case .text:
            bubble(m.text ?? "", mine: mine)
        case .remind:
            if let line = Visits.remindHistoryLine(m, fromMe: mine) {
                chip(String(line.prefix(1)), String(line.dropFirst(2)), mine: mine)
            } else {
                bubble("［新版本消息］", mine: mine, faint: true)
            }
        case .unknown:
            bubble("［新版本消息］", mine: mine, faint: true)
        }
    }

    private func bubble(_ text: String, mine: Bool, faint: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(mine ? Color.white : Color(white: faint ? 0.5 : 0.2))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(mine ? Self.accent : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Self.accent.opacity(mine ? 0 : 0.18), lineWidth: 1))
    }

    private func chip(_ icon: String, _ text: String, mine: Bool) -> some View {
        HStack(spacing: 4) {
            Text(icon).font(.system(size: 13))
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Self.accent)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(mine ? Color(red: 1.0, green: 0.9, blue: 0.82) : Color(red: 1.0, green: 0.95, blue: 0.9)).padding(1).background(Capsule().fill(Self.accent.opacity(0.3))))
    }
}

/// Left-aligned wrapping row: items never break inside, lines wrap between them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let r = rows.count - 1
            rows[r].width += rows[r].items.isEmpty ? size.width : size.width + spacing
            rows[r].height = max(rows[r].height, size.height)
            rows[r].items.append(i)
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
