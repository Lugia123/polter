import Foundation

/// What a tool layout is allowed to do, decided before anything moves
/// (task 1571) -- the half of `TerminalController.applyToolLayout` that
/// needs no window, so it can be tested without one.
///
/// **A layout may name a terminal in any tab of any window, and naming it
/// moves it.** The terminal keeps its view, its surface and its process:
/// tidying by closing and reopening would cut the session in it, which is
/// what the user ruled out. So what is decided here is which of the named
/// terminals leave a tab, and whether every one of them may.
///
/// Generic over the view so a test can use a plain object; the app uses
/// `Ghostty.SurfaceView`.
enum PolterArrangePlan {
    /// Where one terminal is now.
    struct Placed<View: AnyObject> {
        let view: View
        /// The tab it is in: the controller holding it.
        let home: ObjectIdentifier
        /// Shown in the control room right now.
        let lent: Bool
    }

    /// A refusal, with the code the tool answers with.
    struct Refusal: Error, Equatable {
        let code: String
        let message: String

        /// As the core reads it: a bare sentence for `Refused`, and
        /// `{"code","message"}` for any other code (`App.polterRefusal`).
        var wire: String {
            guard code != "Refused" else { return message }
            let obj = ["code": code, "message": message]
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return message }
            return text
        }
    }

    /// What goes ahead: every named view by handle, and the ones that leave
    /// another tab, grouped by the tab they leave.
    struct Plan<View: AnyObject> {
        let byHandle: [UInt: View]
        let leaving: [ObjectIdentifier: [View]]
    }

    /// Decide.
    ///
    /// - `named`: the handles the shape names, in order, duplicates kept.
    /// - `everywhere`: every terminal Polter has open, by handle.
    /// - `destination`: the tab the shape replaces -- its home and what is
    ///   in it now -- or nil for a new tab or window.
    ///
    /// **All or nothing**: the first thing wrong refuses the whole call.
    static func decide<View: AnyObject>(
        named: [UInt],
        everywhere: [UInt: Placed<View>],
        destination: (home: ObjectIdentifier, members: [View])?,
        handleOf: (View) -> String
    ) -> Result<Plan<View>, Refusal> {
        var byHandle: [UInt: View] = [:]
        var leaving: [ObjectIdentifier: [View]] = [:]

        for handle in named {
            guard let placed = everywhere[handle] else {
                return .failure(.init(
                    code: "Refused",
                    message: "0x\(String(handle, radix: 16)) is not a terminal Polter has open. " +
                        "Every cell must name a terminal terminal_list gives you, or ask for " +
                        "a new one with {\"new\": …}."))
            }
            guard byHandle[handle] == nil else {
                return .failure(.init(code: "Refused", message: "the layout names a terminal twice"))
            }
            byHandle[handle] = placed.view

            // ⚠️ **Lent is the control room's, and it is asked of every
            // terminal named** -- the destination's own included: the person
            // is looking at that terminal in the control room, and its home
            // pane is a placeholder they will come back to.
            guard !placed.lent else {
                return .failure(.init(
                    code: "Lent",
                    message: "terminal \(handleOf(placed.view)) is being shown in the control room, " +
                        "and nothing was moved. It goes back to its own pane when the person " +
                        "looks at something else there; try again then."))
            }

            if placed.home != destination?.home {
                leaving[placed.home, default: []].append(placed.view)
            }
        }

        // Every pane that is here must be in the shape, and nothing else.
        // ⚠️ Rearranging is not a way to close a terminal: a shape that
        // leaves one out would destroy it, turning a layout change into
        // something irreversible the caller did not say out loud. Closing
        // is its own verb and has its own confirmation.
        if let destination {
            for view in destination.members where !byHandle.values.contains(where: { $0 === view }) {
                return .failure(.init(
                    code: "Refused",
                    message: "the layout leaves out terminal \(handleOf(view)), which is in this tab. " +
                        "Rearranging never closes a terminal: close it first, then send the " +
                        "layout you want for what is left."))
            }
        }

        return .success(.init(byHandle: byHandle, leaving: leaving))
    }

    /// Where a shape goes, read from the envelope the core sends
    /// (`App.poltergeistLayout`): `{"layout": …, "into": …}`.
    enum Into: Equatable {
        /// The tab of the surface the action was aimed at.
        case here
        /// A new tab to the right of the tab holding this surface handle.
        case newTabBeside(UInt)
        case newWindow
    }

    /// The envelope's two halves. `layout` is handed on to
    /// `PoltergeistLayoutParser`.
    static func envelope(_ value: Any) throws -> (layout: Any, into: Into) {
        guard let obj = value as? [String: Any], let layout = obj["layout"] else {
            throw PoltergeistLayoutError(message: "the layout did not arrive in its envelope")
        }
        guard let into = obj["into"], !(into is NSNull) else { return (layout, .here) }
        guard let intoObj = into as? [String: Any], intoObj.count == 1 else {
            throw PoltergeistLayoutError(message: "\"into\" must be {\"new_tab_beside\":…} or {\"new_window\":true}")
        }
        if let w = intoObj["new_window"] as? Bool, w {
            return (layout, .newWindow)
        }
        if let s = intoObj["new_tab_beside"] as? String,
           let handle = s.hasPrefix("0x") ? UInt(s.dropFirst(2), radix: 16) : UInt(s) {
            return (layout, .newTabBeside(handle))
        }
        throw PoltergeistLayoutError(message: "\"into\" must be {\"new_tab_beside\":…} or {\"new_window\":true}")
    }

    /// Where a tab goes in a strip of `count` tabs, the moving one not
    /// counted: the tab it goes before, or nil for after the last.
    /// `index` is where it ends up, from 0; past the end is the end.
    static func tabSlot(index: Int, othersCount count: Int) -> Int? {
        index < count ? max(0, index) : nil
    }
}
