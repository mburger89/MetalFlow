import Foundation
import MetalUI

/// The right-hand column: what the runs have been doing, newest first.
struct ActivityFeed: Component {
    let model: AppModel
    static let width = Pixels(320)

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: 6) {
            Text("ACTIVITY").font(size: 11).foregroundColor(Palette.muted).accessibilityIdentifier("activity")
            ScrollView {
                // Lazy: up to 200 rows, rebuilt on every update, but only the visible ones are made.
                LazyVStack(alignment: .leading, spacing: Pixels(0)) {
                    ForEach(model.activity, id: \.id) { item in
                        ActivityRow(item: item, now: model.now)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(Edges(all: Spacing.lg))
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Palette.ground)
    }
}

/// One feed line: age, run, text.
struct ActivityRow: Component {
    let item: ActivityItem
    let now: Date

    var content: some ElementGroup {
        let who = item.runTitle.hasPrefix("#") ? String(item.runTitle.split(separator: " ").first ?? "") : item.runTitle
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: ageText(now.timeIntervalSince(item.time))).font(size: 11).foregroundColor(Palette.muted)
                    .frame(width: Pixels(36), alignment: .leading)
                Text(verbatim: "\(who) \(item.text)").font(size: 13).foregroundColor(Self.color(item.kind))
                    .accessibilityIdentifier("activity.item")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(insets(top: 7, right: 0, bottom: 7, left: 0))
            Divider()
        }
    }

    static func color(_ kind: ActivityItem.Kind) -> Color {
        switch kind {
        case .info: Color(Hsla.rgb(0xd7dae0))
        case .needsYou: Tone.warn.color
        case .ok: Tone.ok.color
        case .bad: Tone.bad.color
        case .warn: Tone.warn.color
        }
    }
}
