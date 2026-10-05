import AppKit
import LuluCore
import SwiftUI

/// v0.15.2 what the Settings 「表情」 page needs: the shared prefs model and the stickers the current mode shows.
struct StickerSettingsAccess {
    let model: StickerPrefsModel
    let choices: [ComposeWindow.StickerChoice]
}

/// Settings 「表情」: the 8-slot 快捷栏 on top (◀ ▶ reorder, ✕ remove), every sticker by group below (click = equip).
/// Everything applies at once, also to an open compose panel (same model).
struct StickersPage: View {
    @ObservedObject var model: StickerPrefsModel
    let choices: [ComposeWindow.StickerChoice]
    @State private var message: String?
    @State private var dropTarget: Int?   // v0.15.3 the quick-bar slot a drag hovers over

    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)
    private var visible: [String] { choices.map(\.id) }
    private var byID: [String: ComposeWindow.StickerChoice] { Dictionary(choices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    private func label(_ id: String) -> String { byID[id]?.label ?? id }

    var body: some View {
        let barIDs = StickerPanel.quickBar(stored: model.quickBar, visible: visible)
        let onBar = Set(barIDs)
        // B17: slots held by stickers this mode hides (friend mode) are not free: say so instead of drawing them empty.
        let hiddenCount = StickerPanel.hiddenOnBar(stored: model.quickBar, visible: visible)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("🧸").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text("表情").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("挑 8 个最爱放进快捷栏，像装备栏一样；改了马上生效")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("快捷栏  \(barIDs.count) / \(StickerPanel.maxQuickBar)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Self.accent)
                Spacer(minLength: 0)
                Button("按常用推荐") {
                    model.recommend(visible: visible)
                    message = "已按你发得最多的 8 个重新装好"
                }
                .controlSize(.small)
                .help("用发送次数最多的 8 个表情填满快捷栏")
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(0..<StickerPanel.maxQuickBar, id: \.self) { i in
                    Group {
                        if i < barIDs.count, let s = byID[barIDs[i]] {
                            barTile(s, index: i, count: barIDs.count)
                                .onDrag { NSItemProvider(object: s.id as NSString) }
                        } else if i < barIDs.count + hiddenCount {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.12))
                                .overlay(Text("🔒").font(.system(size: 14)))
                                .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)
                                .help("这一格被朋友模式下隐藏的表情占着")
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Self.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)
                        }
                    }
                    // v0.15.3: drop a bar tile to reorder, or a sticker from below to put it in this slot.
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.accent, lineWidth: dropTarget == i ? 2 : 0))
                    .onDrop(of: [.text], isTargeted: Binding(get: { dropTarget == i }, set: { dropTarget = $0 ? i : (dropTarget == i ? nil : dropTarget) })) { providers in
                        guard let p = providers.first else { return false }
                        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                            guard let id = obj as? String else { return }
                            DispatchQueue.main.async { message = model.drop(id, onto: i, visible: visible, label: label) }
                        }
                        return true
                    }
                }
            }

            if hiddenCount > 0 {
                Text("朋友模式下隐藏了 \(hiddenCount) 个表情，它们还占着快捷栏的格子（换回情侣模式就会出现）")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(message ?? "点下面的表情装上快捷栏（也可以直接拖到某一格），再点一下拿下；拖动或 ◀ ▶ 调顺序，✕ 拿下。发过的表情会按次数自动排进传话面板的「常用」。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(message == nil ? Color.secondary : Self.accent)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(white: 0.45))
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                                ForEach(section.items) { s in pickCell(s, onBar: onBar.contains(s.id)) }
                            }
                        }
                    }
                }
                .padding(.trailing, 10)
            }
            .frame(height: 280)
        }
        .padding(22)
    }

    private var sections: [(title: String, items: [ComposeWindow.StickerChoice])] {
        var out: [(title: String, items: [ComposeWindow.StickerChoice])] = []
        for g in StickerGroup.allCases {
            let items = choices.filter { $0.group == g.rawValue }
            if !items.isEmpty { out.append((g.title, items)) }
        }
        let rest = choices.filter { $0.group.flatMap(StickerGroup.init(rawValue:)) == nil }
        if !rest.isEmpty { out.append(("其他", rest)) }
        return out
    }

    private func thumb(_ s: ComposeWindow.StickerChoice, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let img = s.thumbnail {
                Image(nsImage: img).resizable().aspectRatio(contentMode: s.isWide ? .fit : .fill)
            } else {
                Color.gray.opacity(0.15)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// A quick-bar slot: big tile, ✕ top right, ◀ ▶ underneath.
    private func barTile(_ s: ComposeWindow.StickerChoice, index: Int, count: Int) -> some View {
        VStack(spacing: 2) {
            VStack(spacing: 1) {
                thumb(s, width: 38, height: 30)
                Text(s.label).font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.3)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.accent.opacity(0.4), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button { model.unequip(s.id); message = "已拿下「\(s.label)」" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color(white: 0.55))
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -3)
                .help("从快捷栏拿下")
            }
            HStack(spacing: 2) {
                arrow("chevron.left", enabled: index > 0, help: "左移") { model.move(s.id, by: -1, visible: visible) }
                arrow("chevron.right", enabled: index < count - 1, help: "右移") { model.move(s.id, by: 1, visible: visible) }
            }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
                .frame(width: 18, height: 14)
                .background(RoundedRectangle(cornerRadius: 4).fill(Self.accent.opacity(enabled ? 0.15 : 0.05)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Self.accent : Color.secondary.opacity(0.5))
        .disabled(!enabled)
        .help(help)
    }

    /// One sticker of the whole library: click = equip (or take off when already there).
    private func pickCell(_ s: ComposeWindow.StickerChoice, onBar: Bool) -> some View {
        Button {
            if onBar {
                model.unequip(s.id)
                message = "已拿下「\(s.label)」"
            } else {
                message = model.equip(s.id, visible: visible, label: label)
            }
        } label: {
            VStack(spacing: 1) {
                thumb(s, width: 46, height: 34)
                    .overlay(alignment: .topTrailing) {
                        if onBar { Text("★").font(.system(size: 9)).foregroundStyle(Self.accent).padding(1) }
                    }
                Text(s.label).font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.3)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(onBar ? 1 : 0.85)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.accent.opacity(onBar ? 0.5 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: s.id as NSString) }   // v0.15.3: drag up onto a quick-bar slot
        .help(onBar ? "点一下从快捷栏拿下「\(s.label)」" : "点一下装上快捷栏，或拖到上面某一格")
    }
}
