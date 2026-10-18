import Testing
@testable import Ghostty

/// The dots on a window tab (task 1699): which panes give one, in what
/// order, the supervisor's flag, `+N`, the width and the hover text. The
/// Windows host's rule is held to the same answers by
/// `tools/control-room-hosts-agree.py`.
struct TabDotsTests {
    typealias Pane = TabDots.Pane

    @Test func onlyPanesGivenAColourHaveADotInTheirOrder() {
        let drawn = TabDots.of([
            Pane(name: "a", color: .orange, flag: .none),
            Pane(name: "b", color: .none, flag: .none),
            Pane(name: "c", color: .teal, flag: .none),
        ])
        #expect(drawn.flag == nil)
        #expect(drawn.dots == [.orange, .teal])
        #expect(drawn.plus == 0)
        #expect(drawn.named.map(\.name) == ["a", "c"])
    }

    @Test func theSupervisorLeadsWithItsFlagOnceAndPurpleWhenItHasNoColour() {
        let drawn = TabDots.of([
            Pane(name: "api", color: .orange, flag: .none),
            Pane(name: "boss", color: .none, flag: .raised),
        ])
        #expect(drawn.flag?.0 == .raised)
        #expect(drawn.flag?.1 == .purple)
        // The flag is not one of the dots.
        #expect(drawn.dots == [.orange])
        #expect(drawn.named.map(\.name) == ["boss", "api"])

        let teal = TabDots.of([Pane(name: "boss", color: .teal, flag: .lowered)])
        #expect(teal.flag?.0 == .lowered)
        #expect(teal.flag?.1 == .teal)
    }

    @Test func moreThanEightDrawsSixAndSaysTheRest() {
        let colours: [PaneColor] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .graphite]
        let eight = TabDots.of(colours.prefix(8).map { Pane(name: $0.name, color: $0, flag: .none) })
        #expect(eight.dots.count == 8)
        #expect(eight.plus == 0)
        let nine = TabDots.of(colours.map { Pane(name: $0.name, color: $0, flag: .none) })
        #expect(nine.dots == Array(colours.prefix(6)))
        #expect(nine.plus == 3)
    }

    @Test func theWidthIsTheFlagAndTheColumnsInTheLookTablesNumbers() {
        #expect(TabDots.of([]).width == 0)
        #expect(TabDots.of([Pane(name: "a", color: .red, flag: .none)]).width == 6)
        let flagAndTwo = TabDots.of([Pane(name: "s", color: .none, flag: .raised),
                                     Pane(name: "a", color: .red, flag: .none),
                                     Pane(name: "b", color: .red, flag: .none)])
        // ⚑ 14 + 4 + one column of 6.
        #expect(flagAndTwo.width == 24)
        let colours: [PaneColor] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .graphite]
        let nine = TabDots.of([Pane(name: "s", color: .none, flag: .raised)]
                              + colours.map { Pane(name: $0.name, color: $0, flag: .none) })
        // ⚑ 14 + 4 + three columns (6 + 2 + 6 + 2 + 6); `+3` is not counted.
        #expect(nine.width == 40)
        #expect(TabDots.of(colours.prefix(8).map { Pane(name: "x", color: $0, flag: .none) }).width == 30)
    }

    @Test func theHoverTextNamesEveryPaneAndNothingWhenThereAreNone() {
        #expect(TabDots.tip(TabDots.of([Pane(name: "zsh", color: .none, flag: .none)]), english: true) == "")
        let drawn = TabDots.of([
            Pane(name: "web-app", color: .none, flag: .raised),
            Pane(name: "api", color: .orange, flag: .none),
        ])
        #expect(TabDots.tip(drawn, english: true) == "Panes with a colour\nweb-app, supervisor\napi, Orange")
        // Set to purple by hand is the purple a supervisor has anyway:
        // nothing to say.
        let purple = TabDots.of([Pane(name: "boss", color: .purple, flag: .raised),
                                 Pane(name: "a", color: .orange, flag: .none)])
        #expect(TabDots.tip(purple, english: true) == "Panes with a colour\nboss, supervisor\na, Orange")
        let teal = TabDots.of([Pane(name: "boss", color: .teal, flag: .raised)])
        #expect(TabDots.tip(teal, english: true) == "Panes with a colour\nboss, supervisor, Teal")
    }

    @Test func aPanesColourIsTheCoresNumberAndName() {
        // The raw value is `ghostty_poltergeist_pane_color_e`'s; the name is
        // what the project file and the binding write.
        let names = ["none", "blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "graphite"]
        #expect(PaneColor.allCases.map(\.rawValue) == Array(0..<10))
        #expect(PaneColor.allCases.map(\.name) == names)
        for c in PaneColor.allCases {
            #expect(PaneColor(name: c.name) == c)
        }
        #expect(PaneColor(name: "magenta") == nil)
        #expect(PaneColor.orange.bindingAction == "poltergeist_set_pane_color:orange")
        #expect(PaneColor.shown(set: .none, supervisor: true) == .purple)
        #expect(PaneColor.shown(set: .none, supervisor: false) == PaneColor.none)
        #expect(PaneColor.shown(set: .green, supervisor: true) == .green)
    }

    @Test func everyColourButNoneHasItsThreeLookTableValuesInBothThemes() {
        for dark in [false, true] {
            let theme = ControlRoomLook.theme(dark: dark)
            #expect(PaneColor.none.dot(theme) == nil)
            for c in PaneColor.allCases where c != .none {
                #expect(c.dot(theme) != nil && c.badge(theme) != nil && c.badgeText(theme) != nil, "\(c)")
            }
            // The supervisor's badge with no colour of its own is purple's.
            #expect(PaneFrame.badgeGround(.none, theme: theme) == theme.panePurpleBadge)
            #expect(PaneFrame.badgeGround(.orange, theme: theme) == theme.paneOrangeBadge)
        }
    }
}
