# Markdown Preview Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Markdown where the text is Markdown: the prompt and note editors in the Inspector get an Edit/Preview toggle, and agent output and questions in run detail render as Markdown.

**Architecture:** A pure-Swift block parser splits text into blocks (headings, paragraphs, bullet and numbered lists, fenced code, block quotes, rules). Each paragraph's inline spans go through Foundation's `AttributedString(markdown:options:)` with `.inlineOnlyPreservingWhitespace`, the same parse SwiftUI uses. MetalUI's `Text` draws the result. MetalUI's own parser is inline only, so the block layer is ours.

**Tech Stack:** Swift, Swift Testing, MetalUI (path dependency, do not patch it).

## Decisions

These are the planner's calls. The user asked for "markdown preview", not for a list of views, so they should redirect me if the scope is wrong.

1. **Authored text gets a toggle.** The Inspector's Prompt editor and the Note editor each get an Edit/Preview toggle. Edit is the default. The toggle is per node or note, and is not saved.
2. **Read-only text renders by default.** Agent output (the run detail's node output), question text (run detail's `needsYou(.question)` row and the Needs-you section) render as Markdown with no toggle. A raw view is not needed, since output is not edited.
3. **Canvas sticky notes stay plain.** They are too small for a preview; their full text shows in the Inspector's note view when selected. Revisit later if the user wants it.
4. **Block support:** headings `#`–`######`, paragraphs (soft line breaks kept), `-`/`*`/`+` bullets, `1.` numbered lists, fenced code blocks (``` with optional language, shown verbatim in mono), `>` block quotes, and `---` rules. Tables, images, HTML and footnotes are shown as plain paragraphs.
5. **Inline:** `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `[text](url)` (shown styled; links are not clickable in v1, matching MetalUI's link runs). Done by `AttributedString(markdown:options:)`, not hand-written.
6. **Fallback:** if inline parsing throws for a paragraph, that paragraph is shown verbatim. Nothing is lost.

## Global Constraints

- Test command (zsh, literal flags): `swift test --no-parallel -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing > <scratchpad>/x.log 2>&1`, then grep the summary.
- Baseline before this work: Core 374, Kit 420, mflow 64. Only `recordsAnIssueAtTheDeadline` may fail (Kit and Core).
- Commit only with the messages given. No attribution trailer. Do not push.
- Reuse the existing styling: `Palette`, `Theme.mono`, `font(size:)`, and the card and field styles used in `InspectorView` and `RunDetailView`.
- Read first: `Sources/MetalFlowKit/Studio/InspectorView.swift` (around lines 540–570 for the prompt and tools editors, and near line 118 for the note), `Sources/MetalFlowKit/Studio/NoteViews.swift`, `Sources/MetalFlowKit/RunDetail/RunDetailView.swift` (near lines 109 and 183), `Sources/MetalFlowKit/Dashboard/NeedsYouSection.swift`, and MetalUI's `Sources/MetalUI/TextAttributes.swift` around line 211 for how an `AttributedString` is drawn.

## Task 1: Block parser (pure)

**Files:** `Sources/MetalFlowKit/Markdown/MarkdownBlocks.swift` (new), `Tests/MetalFlowKitTests/MarkdownBlocksTests.swift` (new).

- [ ] `enum MarkdownBlock: Equatable`: `.heading(level: Int, text: String)`, `.paragraph(String)`, `.bullets([String])`, `.numbered([String])`, `.code(language: String?, text: String)`, `.quote(String)`, `.rule`.
- [ ] `enum MarkdownBlocks { static func parse(_ text: String) -> [MarkdownBlock] }`, pure, no Foundation beyond String.
- [ ] Tests: each block kind; paragraphs separated by blank lines; a soft line break stays inside one paragraph; an unclosed code fence runs to the end; a `#` with no space is a paragraph; `1.` lists; nested bullets are flattened into the item text (no nesting in v1); empty input gives `[]`.
- [ ] Run Kit tests. Commit: `Parse Markdown into blocks`.

## Task 2: Renderer and toggle

**Files:** `Sources/MetalFlowKit/Markdown/MarkdownView.swift` (new), `Sources/MetalFlowKit/Markdown/MarkdownPreviewToggle.swift` (new), `Tests/MetalFlowKitTests/MarkdownViewTests.swift` (new).

- [ ] `MarkdownView(text:)` renders blocks as a vertical stack: headings bigger and bold, bullets with a `•` marker, numbered lists with `n.`, code in `Theme.mono` on a muted fill, quotes with a left bar in `Palette.muted`, rules as a 1pt line. Inline runs come from `AttributedString(markdown:options:)` with `.inlineOnlyPreservingWhitespace`; on error, show the paragraph verbatim (decision 6).
- [ ] `MarkdownPreviewToggle`: a two-segment control, Edit / Preview, bound to a Bool. Identifiers `markdown.edit` and `markdown.preview`.
- [ ] Tests: the view's block model for a known input (use `MarkdownBlocks.parse` output as the seam, not drawn pixels); inline parse fallback returns the verbatim paragraph.
- [ ] Run Kit tests. Commit: `Render Markdown blocks and add an Edit/Preview toggle`.

## Task 3: Wire the surfaces

**Files:** `Sources/MetalFlowKit/Studio/InspectorView.swift`, `Sources/MetalFlowKit/Studio/NoteViews.swift`, `Sources/MetalFlowKit/RunDetail/RunDetailView.swift`, `Sources/MetalFlowKit/Dashboard/NeedsYouSection.swift`, `Sources/MetalFlowKit/App/AppModel.swift` (only if a preview-state dictionary is needed; keep it per node key in memory), tests in the matching `*Tests.swift`.

- [ ] Prompt editor: when Preview is on, show `MarkdownView(text: prompt)` in place of the `TextEditor` (same height). Edit keeps the existing `TextEditor` and its bindings unchanged. Accessibility id on the preview: `inspector.prompt.preview`.
- [ ] Note editor in the Inspector: same toggle and behaviour. Keep the existing `note.text` binding.
- [ ] Run detail: node output (`RunDetailView` near line 109) and question text (near line 183) render with `MarkdownView` instead of `Text(verbatim:)`. Keep the existing identifiers.
- [ ] Needs-you section: the question text renders with `MarkdownView` where a question is shown.
- [ ] Tests: the preview toggle switches the Inspector prompt between editor and preview; a question with Markdown in it renders its heading as a heading block; existing identifiers are unchanged (update any test that asserted verbatim text in these views).
- [ ] Run the full suite. Expect baseline plus new, with only the known issue failing.
- [ ] Commit: `Show Markdown in the prompt and note editors and in run output`.

## Verification

- [ ] Full suite passes apart from the known issue.
- [ ] On-screen check of the rendered output in the packaged app, once the desktop is free and computer use is granted. The user has said this can wait; list it as unverified until then.
