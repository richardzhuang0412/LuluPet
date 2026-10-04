import AppKit
import LuluCore
import SwiftUI

/// v0.13.3 weather card at the top of the compose panel's 传话 tab (replaces the one-line v0.12 text and the v0.12
/// desktop widget): TA's row first, then mine (solo: only mine). No timers of its own: the clock and the age label ride
/// on a once-a-minute `TimelineView` that exists only while the panel is open.

/// One person's row.
struct WeatherRow: Identifiable, Equatable {
    var id: String
    var label: String             // "TA" / "我"
    var avatar: NSImage?          // tiny idle frame of the character; nil → `emoji`
    var emoji: String             // fallback avatar
    var place: WeatherPlace
    var snapshot: WeatherSnapshot?
}

/// What the card shows. `hasMyCity == false` adds the 「设置我的城市」 link; no rows and a city = nothing to show.
struct WeatherCardData: Equatable {
    var rows: [WeatherRow] = []
    var hasMyCity = true
    var isEmpty: Bool { rows.isEmpty && hasMyCity }
}

final class WeatherCardModel: ObservableObject {
    @Published var data = WeatherCardData()
}

struct WeatherCardView: View {
    @ObservedObject var model: WeatherCardModel
    var onOpenSettings: () -> Void

    var body: some View {
        let d = model.data
        if !d.isEmpty {
            TimelineView(.everyMinute) { ctx in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(d.rows) { WeatherRowView(row: $0, now: ctx.date) }
                    if !d.hasMyCity {
                        Button(action: onOpenSettings) {
                            Text("设置我的城市 ›")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.93, green: 0.52, blue: 0.16))
                        }
                        .buttonStyle(.plain)
                        .help("在 设置 → 通用 里选一个城市")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
            }
        }
    }
}

private struct WeatherRowView: View {
    let row: WeatherRow
    let now: Date

    private var fresh: WeatherSnapshot? {
        row.snapshot.flatMap { WeatherRefresh.isStale(fetchedAt: $0.fetchedAt, now: now.timeIntervalSince1970) ? nil : $0 }
    }

    var body: some View {
        HStack(spacing: 8) {
            avatar.frame(width: 22, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(row.label).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(Color(white: 0.5))
                    Text(row.place.name).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Color(white: 0.2)).lineLimit(1)
                }
                Text(timeLine).font(.system(size: 10, design: .rounded)).foregroundStyle(Color(white: 0.45)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let s = fresh {
                Text(s.condition.emoji(isDay: s.isDay)).font(.system(size: 20))
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(s.temperature.rounded()))°").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color(white: 0.2))
                    if let h = s.high, let l = s.low {
                        Text("\(Int(h.rounded()))° / \(Int(l.rounded()))°").font(.system(size: 9)).foregroundStyle(Color(white: 0.5)).monospacedDigit()
                    }
                }
            } else {
                Text(WeatherText.unavailable).font(.system(size: 10, design: .rounded)).foregroundStyle(Color(white: 0.55))
            }
        }
        .frame(height: 30)
    }

    private var timeLine: String {
        var out = WeatherText.localTime(timezone: row.place.timezone, now: now)
        if let s = fresh, let age = WeatherRefresh.ageLabel(fetchedAt: s.fetchedAt, now: now.timeIntervalSince1970) { out += " · \(age)" }
        return out
    }

    @ViewBuilder private var avatar: some View {
        if let img = row.avatar {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Text(row.emoji).font(.system(size: 20))
        }
    }
}
