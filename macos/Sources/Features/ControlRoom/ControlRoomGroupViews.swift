import AppKit
import SwiftUI

// The pieces the group row's menu brings onto the list (task 1660, design
// v21): the pinned and muted marks, the name made a field for renaming and
// the line under it, the line that says the supervisor was asked, and the
// note's panel. The design gives their structure and where they go; every
// size, face and colour is `ControlRoomLook`'s -- the user, 2026-10-16: the
// two designs differ in their numbers, and the product's own are the ones.

/// To the right of a group's name: pinned, then muted, `side.mark_gap`
/// apart, each `side.glyph` square, in the tertiary text colour. Not in the
/// glyph column at the left, which says only what the group is doing, so
/// neither is read as a status.
struct ControlRoomRowMarks: View {
    typealias Look = ControlRoomLook

    var pinned: Bool
    var muted: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if pinned || muted {
            HStack(spacing: CGFloat(Look.Side.markGap)) {
                if pinned { mark("pin.fill") }
                if muted { mark("bell.slash") }
            }
            .foregroundStyle(Look.theme(scheme).textTertiary.color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(pinned: pinned, muted: muted))
        }
    }

    private func mark(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
    }

    /// What a screen reader says for the marks.
    static func spoken(pinned: Bool, muted: Bool) -> String {
        switch (pinned, muted) {
        case (true, true): return String(localized: "Pinned, muted", comment: "总控台：群行名字右边的标识，读屏用：置顶、静音")
        case (true, false): return String(localized: "Pinned", comment: "总控台：群行名字右边的标识，读屏用：置顶")
        case (false, true): return String(localized: "Muted", comment: "总控台：群行名字右边的标识，读屏用：静音")
        case (false, false): return ""
        }
    }
}

/// A group's name made a field, where the name was (design v21 `03`): its
/// face and size the name's, its text starting where the name's did, the
/// whole name selected. Return renames; Escape gives up; the keyboard going
/// elsewhere renames too, as in the Finder. While the name is refused the
/// field's edge is the problem colour and Return does nothing.
struct ControlRoomRenameField: View {
    typealias Look = ControlRoomLook

    @Binding var text: String
    /// Why the name as it stands would be refused; nil when it would not.
    var refused: Bool
    /// The size the name is set in on its row.
    var size: Double
    var onSubmit: () -> Void
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        let theme = Look.theme(scheme)
        let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: CGFloat(size), design: .monospaced))
            .focused($focused)
            .onSubmit(onSubmit)
            .onExitCommand(perform: onCancel)
            // The box reaches `header_item_gap` past the name on each side
            // and its text starts where the name's did.
            .padding(.horizontal, CGFloat(Look.Side.headerItemGap))
            .frame(maxHeight: .infinity)
            .background(shape.strokeBorder((refused ? theme.problem : theme.attentionText).color,
                                           lineWidth: CGFloat(refused ? Look.Line.stroke : Look.Line.hairline)))
            .padding(.horizontal, -CGFloat(Look.Side.headerItemGap))
            .onAppear {
                // On the next turn: the menu that opened it is still handing
                // the keyboard back as it closes, and a field focused before
                // that lost it to the list (poltertest, task 1660) -- where
                // what was typed went nowhere and Return went to the
                // supervisor. Then the whole name, ready to be typed over,
                // once the field editor is there to hold the selection.
                DispatchQueue.main.async {
                    focused = true
                    DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                }
            }
            .onChange(of: focused) { has in
                if !has { onSubmit() }
            }
            .accessibilityLabel(String(localized: "Rename Group", comment: "总控台：行内改名的输入框，读屏用"))
    }
}

/// One line in the problem colour under a row: why its new name is
/// refused. Its text starts where the name's does.
struct ControlRoomRowRefusal: View {
    typealias Look = ControlRoomLook

    var text: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .foregroundStyle(Look.theme(scheme).problemTextOnRow.color)
            .lineLimit(1)
            .truncationMode(.tail)
            // All of it, where one line cuts it.
            .help(text)
            .frame(maxWidth: .infinity, minHeight: CGFloat(Look.Side.askLineHeight),
                   maxHeight: CGFloat(Look.Side.askLineHeight), alignment: .leading)
    }
}

/// The line under a row once its supervisor was asked something (design
/// v21 `07`, done the first way): a check and what was asked, in the
/// secondary colour, folding away after `group_note.feedback_seconds`; or,
/// when it did not go in, the problem glyph and why in the problem colour,
/// staying. Which of the two, and when it folds, is the caller's.
struct ControlRoomAskedLine: View {
    typealias Look = ControlRoomLook

    var text: String
    var delivered: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        HStack(spacing: CGFloat(Look.Side.quietItemGap)) {
            Image(systemName: delivered ? "checkmark" : "exclamationmark.triangle.fill")
                .foregroundStyle((delivered ? theme.textSecondary : theme.problem).color)
                .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
            Text(text)
                .foregroundStyle((delivered ? theme.textSecondary : theme.problemTextOnRow).color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(text)
        .frame(maxWidth: .infinity, minHeight: CGFloat(Look.Side.askLineHeight),
               maxHeight: CGFloat(Look.Side.askLineHeight), alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The group's note, edited in a panel docked at the window's right
/// (design v21 `04-B`, the user's choice): the group's name and whose the
/// note is, the box with the note in it filling what is left, and along
/// the bottom how long it is and the two buttons, drawn as the Settings
/// window draws its own. No close button at the top (the user,
/// 2026-10-16): the bottom left button closes it, giving up the changes
/// when there are any; Escape is the same.
struct ControlRoomNotePanel: View {
    typealias Look = ControlRoomLook

    var group: String
    /// What the group's note is now: what "discard" goes back to.
    var saved: String
    @Binding var text: String
    /// Why the last save was refused, said where the count is.
    var refusal: String?
    var onSave: () -> Void
    var onClose: () -> Void

    @Environment(\.colorScheme) private var scheme
    @FocusState private var editing: Bool

    private var changed: Bool { text != saved }

    var body: some View {
        let theme = Look.theme(scheme)
        let pad = CGFloat(Look.Side.headerPaddingX)
        let box = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
        VStack(alignment: .leading, spacing: CGFloat(Look.Side.rowGap)) {
            VStack(alignment: .leading, spacing: CGFloat(Look.Side.headerItemGap)) {
                Text(String(format: String(localized: "%@'s note", comment: "总控台：群简介面板的标题，%@ 是群名"), group))
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                Text(String(localized: "The group's supervisor and workers can all read this.",
                            comment: "总控台：群简介面板标题下的一句"))
                    .foregroundStyle(theme.textSecondary.color)
            }
            .frame(minHeight: CGFloat(Look.Side.headerHeight), alignment: .leading)
            TextEditor(text: $text)
                .font(.system(size: CGFloat(Look.Font.body)))
                .scrollContentBackground(.hidden)
                .focused($editing)
                .padding(CGFloat(Look.Side.rowPaddingY))
                .background(box.fill(theme.windowBase.color))
                .overlay(box.strokeBorder((editing ? theme.attentionText : theme.line).color,
                                          lineWidth: CGFloat(Look.Line.hairline)))
                .accessibilityLabel(String(format: String(localized: "%@'s note", comment: "总控台：群简介面板的标题，%@ 是群名"), group))
            HStack(spacing: CGFloat(Look.Side.rowItemGap)) {
                Text(refusal ?? ControlRoomGroupWords.noteCount(text, changed: changed))
                    .foregroundStyle((refusal == nil ? theme.textSecondary : theme.problemTextOnRow).color)
                    .monospacedDigit()
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button(changed
                       ? String(localized: "Discard Changes", comment: "总控台：群简介面板，放弃改动并关上")
                       : String(localized: "Close", comment: "总控台：群简介面板，没改动时关上")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", comment: "总控台：群简介面板，保存")) { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed)
            }
            // As the Settings window's bottom bar sets its buttons.
            .controlSize(.large)
        }
        .padding(pad)
        .frame(width: CGFloat(Look.GroupNote.panelWidth))
        .frame(maxHeight: .infinity)
        .background(ControlRoomSidePanel())
        .font(.system(size: CGFloat(Look.Font.body)))
        .foregroundStyle(theme.text.color)
        .onAppear { DispatchQueue.main.async { editing = true } }
    }
}

/// Over a row: a right-click there opens `menu` at the pointer, as the
/// system's context menus open (task 1660). Every other click goes through
/// to the row underneath -- the view takes part in hit testing only for a
/// right mouse button, or a click with Control held.
struct ControlRoomRightClick: NSViewRepresentable {
    var menu: () -> NSMenu?

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.menu = nil
        view.make = menu
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.make = menu
    }

    final class Catcher: NSView {
        var make: () -> NSMenu? = { nil }

        /// Whether `event` is the system's "show the menu" click.
        static func isMenuClick(_ event: NSEvent?) -> Bool {
            guard let event else { return false }
            switch event.type {
            case .rightMouseDown: return true
            case .leftMouseDown: return event.modifierFlags.contains(.control)
            default: return false
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            Self.isMenuClick(NSApp.currentEvent) ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            show(event)
        }

        override func mouseDown(with event: NSEvent) {
            if Self.isMenuClick(event) { show(event) } else { super.mouseDown(with: event) }
        }

        private func show(_ event: NSEvent) {
            guard let menu = make() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

/// "Archived (N)" at the bottom of the list (task 1661's layout, design v21
/// `06`): it opens and closes the groups put away. A view of its own, as
/// "Fix" is (`ControlRoomFixLine`), so the list itself keeps its one button
/// (`tools/control-room-rows-only-tell.py`): this answers nothing for
/// anybody, it only shows more of the list.
struct ControlRoomArchivedHeader: View {
    typealias Look = ControlRoomLook

    var count: Int
    var open: Bool
    var onToggle: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: CGFloat(Look.Side.headerItemGap)) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                Text(ControlRoomGroupWords.archivedHeader(count))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Look.theme(scheme).textSecondary.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CGFloat(Look.Side.headerPaddingX))
        .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
    }
}
