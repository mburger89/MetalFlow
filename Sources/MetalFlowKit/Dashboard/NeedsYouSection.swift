import MetalFlowCore
import MetalUI

/// A section heading: a small caps title and a muted subtitle.
struct SectionHeader: Component {
    let title: String
    let subtitle: String
    var id: String
    var color: Color = Palette.muted

    var content: some ElementGroup {
        HStack(spacing: Spacing.sm) {
            Text(verbatim: title).font(size: 11).foregroundColor(color).accessibilityIdentifier(id)
            Text(verbatim: subtitle).font(size: 12).foregroundColor(Palette.muted)
        }
    }
}

/// Cards for everything that waits on the user.
struct NeedsYouSection: Component {
    let model: AppModel

    var content: some ElementGroup {
        let items = model.needsItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(title: "NEEDS YOU", subtitle: "Waits here until you get to it", id: "needs", color: Palette.warn)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Pixels(280)))], spacing: Spacing.sm) {
                    ForEach(items, id: \.id) { item in
                        NeedsCard(model: model, item: item)
                    }
                }
            }
        }
    }
}

/// One needs-you card: kind, title, detail and the primary action beside "Open run".
struct NeedsCard: Component {
    let model: AppModel
    let item: NeedsItem

    var content: some ElementGroup {
        let run = item.run
        let (label, detail, color) = Self.describe(item)
        let id = item.id
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label).font(size: 11).foregroundColor(color).accessibilityIdentifier("\(id).label")
            Text(verbatim: run.title).font(size: 13).foregroundColor(Palette.text)
            Text(verbatim: detail).font(size: 13).foregroundColor(Palette.body)
            if case .question = item.kind {
                AnswerBox(model: model, runID: run.id, key: item.key)
            }
            HStack(spacing: 6) {
                primary
                Button("Open run") { model.open(run: run.id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(id).open")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Edges(all: Spacing.md))
        .background(Color(Hsla.rgb(0x1a1712)))
        .cornerRadius(10)
        .border(color, width: 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    @ElementBuilder
    private var primary: some ElementGroup {
        let run = item.run
        let model = model
        let key = item.key
        // A question's primary action is its reply box above, so it has no button here.
        if case .pickWinner = item.kind {
            Button("Compare & pick") { model.open(run: run.id) }
                .buttonStyle(.bordered).accessibilityIdentifier("\(item.id).primary")
        }
        if case .deniedTools(let tools) = item.kind {
            Button("Allow") { Task { await model.allowAndContinue(run: run.id, node: key, tools: tools) } }
                .buttonStyle(.bordered).accessibilityIdentifier("\(item.id).primary")
        }
        if case .interrupted = item.kind {
            Button("Resume") { Task { await model.resume(run.id) } }
                .buttonStyle(.bordered).accessibilityIdentifier("\(item.id).primary")
        }
        if case .failed = item.kind {
            Button("Retry") { Task { await model.retry(run.id, node: key) } }
                .buttonStyle(.bordered).accessibilityIdentifier("\(item.id).primary")
        }
    }

    static func describe(_ item: NeedsItem) -> (String, String, Color) {
        switch item.kind {
        case .pickWinner(let recommended, let allFailed):
            if allFailed { return ("GATE FAILED", "All candidates fail the gate", Palette.bad) }
            let hint = recommended.map { "Judge recommends \($0.uppercased())" } ?? "Candidates are ready"
            return ("PICK A WINNER", hint, Palette.warn)
        case .question(let q): return ("QUESTION", q, Palette.warn)
        case .deniedTools(let tools): return ("APPROVAL", "Needs approval for \(tools.joined(separator: ", "))", Palette.warn)
        case .interrupted: return ("INTERRUPTED", "\(item.key) was cut short", Palette.warn)
        case .failed(let message): return ("FAILED", "\(item.key): \(message)", Palette.bad)
        }
    }
}
