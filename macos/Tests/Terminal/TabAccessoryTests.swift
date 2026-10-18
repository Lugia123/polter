import Testing
@testable import Ghostty

/// What is beside a tab's title for a given mark and zoom state.
///
/// **The rule these exist for: having no mark hides the mark and nothing
/// else.** The mark used to own the whole accessory slot and cleared it
/// when it was empty, which took the shortcut hint, the colour dot and the
/// reset-zoom button away from every unmarked tab (#67).
struct TabAccessoryTests {
    @Test func aTabWithoutAMarkStillHasItsShortcutHint() {
        let visible = TabAccessory.visibleItems(.init())
        #expect(visible == [.keyEquivalent])
    }

    @Test func aMarkIsAddedBesideTheOthersNotInsteadOfThem() {
        let visible = TabAccessory.visibleItems(.init(poltergeistMark: "⚑ "))
        #expect(visible == [.poltergeistMark, .keyEquivalent])
    }

    @Test func aMarkOfOnlySpacesIsNoMark() {
        let visible = TabAccessory.visibleItems(.init(poltergeistMark: "  "))
        #expect(!visible.contains(.poltergeistMark))
    }

    @Test func resetZoomShowsOnlyWhileZoomedWithOrWithoutAMark() {
        let unmarked = TabAccessory.visibleItems(.init(surfaceIsZoomed: true))
        #expect(unmarked == [.keyEquivalent, .resetZoom])

        let marked = TabAccessory.visibleItems(.init(poltergeistMark: "⚑ ", surfaceIsZoomed: true))
        #expect(marked == [.poltergeistMark, .keyEquivalent, .resetZoom])
    }

    @Test func visibleItemsKeepTheLayoutOrder() {
        // The stack is built from `Item.allCases`, so a visible list in any
        // other order would describe a layout the window does not have.
        let all = TabAccessory.Item.allCases
        for mark in ["", "⚑ "] {
            for zoomed in [false, true] {
                let visible = TabAccessory.visibleItems(
                    .init(poltergeistMark: mark, surfaceIsZoomed: zoomed))
                let inLayoutOrder = all.filter { visible.contains($0) }
                #expect(visible == inLayoutOrder)
            }
        }
    }

    @Test func theMarkIsDrawnWithoutTheSpaceItCarriedAsATitlePrefix() {
        #expect(TabAccessory.markText("⚑ ") == "⚑")
        #expect(TabAccessory.markText("") == "")
    }
}
