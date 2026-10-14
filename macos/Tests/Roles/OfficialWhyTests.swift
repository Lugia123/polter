import Foundation
import Testing
@testable import Ghostty

/// The reasons a change to an official role or skill could not be read, in
/// the person's language (task 1514). Whether the core's names and these
/// agree is `tools/official-why-codes-agree.py`; this is what the window does
/// with a name once it has one.
struct OfficialWhyTests {
    @Test func aNamedReasonIsSaidInTheWindowsOwnWordsWithItsDetail() {
        let shown = OfficialWhy.display(
            code: "role_no_base", detail: "instructions",
            english: "\"instructions\" has no base, so it cannot be compared with the official version")
        #expect(shown == OfficialWhy.roleNoBase.text("instructions"))
        #expect(shown?.contains("instructions") == true)
    }

    @Test func aReasonTheCoreDidNotNameIsShownAsTheCoreWroteIt() {
        #expect(OfficialWhy.display(code: nil, detail: nil, english: "out of memory") == "out of memory")
        #expect(OfficialWhy.display(code: "a_name_from_a_newer_core", detail: "x", english: "words") == "words")
        #expect(OfficialWhy.display(code: nil, detail: nil, english: nil) == nil)
    }

    @Test func everyReasonWithAPlaceForTheDetailPutsItThere() {
        for why in OfficialWhy.allCases {
            let text = why.text("DETAIL-1514")
            #expect(!text.isEmpty, "\(why) says nothing")
            #expect(!text.contains("%@"), "\(why) left its placeholder unfilled")
        }
        // The ones with a variable part show it.
        for why in [OfficialWhy.overridesUnreadable, .roleUnknownField, .roleNotValueAndBase, .roleNoValue,
                    .roleValueUnreadable, .roleNoBase, .roleBaseUnreadable, .skillCopyNotThisSkill] {
            #expect(why.text("DETAIL-1514").contains("DETAIL-1514"), "\(why) lost its detail")
        }
    }
}
