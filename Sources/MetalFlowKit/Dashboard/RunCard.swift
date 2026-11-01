import Foundation
import MetalFlowCore
import MetalUI

/// "40s", "6m", "1h 5m".
func elapsedText(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

/// A running run: title, flow, branch, elapsed time, step pills, the latest log line and Cancel.
struct RunCard: Component {
    let model: AppModel
    let run: Run

    var content: some ElementGroup {
        let id = run.id
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(verbatim: run.title).font(size: 13).foregroundColor(Palette.text)
                .accessibilityIdentifier("run.\(id.rawValue).title")
                .lineLimit(1)
            HStack(spacing: Spacing.sm) {
                Chip(text: run.flow.name, mono: false)
                Chip(text: run.branch, mono: true)
                Spacer()
                TimelineView(.periodic(from: run.createdAt, by: 1)) { context in
                    Text(verbatim: elapsedText(context.date.timeIntervalSince(run.createdAt)))
                        .font(size: 11).foregroundColor(Palette.muted)
                        .accessibilityIdentifier("run.\(id.rawValue).elapsed")
                }
            }
            StepPills(pills: run.stepPills)
            HStack(spacing: 0) {
                Text(verbatim: run.lastLogLine ?? " ")
                    .font(Theme.mono(11.5)).foregroundColor(Palette.muted)
                    .accessibilityIdentifier("run.\(id.rawValue).log")
                    .lineLimit(1)
                Spacer()
            }
                .frame(maxWidth: .infinity)
                .padding(insets(top: 6, right: 8, bottom: 6, left: 8))
                .background(Palette.ground)
                .cornerRadius(6)
            HStack(spacing: Spacing.sm) {
                Button("Open") { model.open(run: id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("run.\(id.rawValue).open")
                if model.runningElsewhere.contains(id) {
                    // Another process holds the run's lock: cancelling from here would do nothing.
                    Text(verbatim: "Running in another mflow").font(size: 12).foregroundColor(Palette.muted)
                        .accessibilityIdentifier("run.\(id.rawValue).elsewhere")
                } else {
                    Button("Cancel") { Task { await model.cancel(id) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("run.\(id.rawValue).cancel")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Edges(all: Spacing.md))
        .background(Palette.panel)
        .roundedBorder(Palette.line, radius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run.\(id.rawValue)")
    }
}

/// A small rounded label.
struct Chip: Component {
    let text: String
    let mono: Bool

    var content: some ElementGroup {
        Text(verbatim: text)
            .font(mono ? Theme.mono(11) : Font.system(size: 11))
            .foregroundColor(Color(Hsla.rgb(0xb9c0ca)))
            .lineLimit(1)
            .padding(insets(top: 2, right: 6, bottom: 2, left: 6))
            .background(Color(Hsla.rgb(0x1f232a)))
            .cornerRadius(4)
    }
}
