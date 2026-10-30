import Foundation
import MetalUI

/// The right-hand column: what the runs have been doing, newest first.
struct ActivityFeed: Component {
    let model: AppModel
    static let width = Pixels(320)
    static let shown = 100

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: 6) {
            Text("ACTIVITY").font(size: 11).foregroundColor(Palette.muted).accessibilityIdentifier("activity")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.activity.prefix(Self.shown)), id: \.id) { item in
                        ActivityRow(item: item)
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

    var content: some ElementGroup {
        let who = item.runTitle.hasPrefix("#") ? String(item.runTitle.split(separator: " ").first ?? "") : item.runTitle
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: ageText(Date().timeIntervalSince(item.time))).font(size: 11).foregroundColor(Palette.muted)
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
        case .needsYou: Palette.warn
        case .ok: Palette.ok
        case .bad: Palette.bad
        }
    }
}
