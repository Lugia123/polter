import Foundation
import Testing
@testable import Ghostty

/// Covers the two JSON decoders the persona interface hangs off:
/// `ghostty_surface_persona_face`'s payload and
/// `ghostty_app_persona_hosts`'s.
///
/// **The two "today" cases are the core's literals, copied byte for byte**
/// out of `src/apprt/embedded.zig`, because those are what every terminal
/// actually returns right now. A decoder tested only against the shape in
/// the contract would be tested against a document; these are tested against
/// the program.
@Suite
struct PersonaDecodingTests {
    // MARK: What the core returns today

    /// `ghostty_surface_persona_face` for a terminal with no persona, in the
    /// shape the core renders since it started reading `personas.json`.
    private let faceToday = #"{"key":null,"name":null,"deviated":false,"epoch":0,"roster":0,"agent_present":false,"host_class":"unknown","prompt":null,"skills":[],"mcp":[],"error":null,"error_kind":null,"stale":false}"#

    /// What the core sends when it has nothing to report: `personas.json`
    /// has not been read, or rendering the face failed. **Deliberately not a
    /// full face** -- the core chose to send this rather than pad every
    /// field, so the decoder has to survive it.
    private let faceNotRead = #"{"stale":true}"#

    /// `ghostty_app_persona_hosts`, verbatim.
    private let hostsToday = #"{"stale":true,"hosts":[]}"#

    @Test func theEmptyFaceDecodesAsAskedAndEmptyNotAsUnasked() throws {
        let face = try #require(PersonaFace(json: faceToday))

        // The distinction the whole pane rests on: a well-formed answer with
        // nothing in it is *known*. Only a missing answer is unknown.
        #expect(face.isKnown)
        #expect(face.isEmpty)
        #expect(face.epoch == 0)
        #expect(!face.deviates)
        #expect(face.loadError == nil)
        #expect(face.errorKind == nil)
    }

    /// The collapse `stale` exists to prevent, on this side of the wire.
    ///
    /// Without it a terminal nobody has read for decodes as a perfectly good
    /// face with nothing in it, and the editor says "this terminal hands out
    /// nothing" -- a sentence that never resolves itself, about a question
    /// that was never asked.
    @Test func aFaceNobodyHasReadYetIsNotAFaceWithNothingInIt() throws {
        let unread = try #require(PersonaFace(json: faceNotRead))
        let empty = try #require(PersonaFace(json: faceToday))

        #expect(!unread.isKnown)
        #expect(empty.isKnown)

        // Both are empty. Only one of them is empty *as an answer*.
        #expect(unread.isEmpty)
        #expect(empty.isEmpty)
    }

    @Test func aStaleHostListIsNotAnEmptyOne() throws {
        let inventory = try #require(HostInventory(json: hostsToday))

        // `stale` says the core has not finished scanning. Drawn as an empty
        // list it would tell the user this machine has nothing installed,
        // which is a different sentence and a false one.
        #expect(inventory.stale)
        #expect(!inventory.isKnown)
    }

    @Test func rubbishDecodesToNothingRatherThanToEmpty() {
        #expect(PersonaFace(json: "not json") == nil)
        #expect(HostInventory(json: "not json") == nil)
        #expect(PersonaFace(json: "[]") == nil)
    }

    // MARK: A face with something in it

    private let faceWorn = #"""
    {"key":"archer","name":"Archer","deviated":true,"epoch":8,"roster":3,"agent_present":true,
     "host_class":"cold","prompt":"archer.md",
     "skills":[{"id":"3-0","name":"reading-a-terminal","enabled":false,"in_persona":true},
               {"id":"3-1","name":"extra","enabled":true,"in_persona":false}],
     "mcp":[{"id":"3-0","name":"argus","enabled":true,"in_persona":true,"slot":"broken"}],
     "error":null,"error_kind":null,"stale":false}
    """#

    @Test func idsComeFromTheCoreAndAreNotRebuiltHere() throws {
        let face = try #require(PersonaFace(json: faceWorn))

        // The two version numbers are different numbers and both survive.
        // Ids are minted from `roster`, not from `epoch` -- reconstructing
        // one here from the other would produce "8-0" and miss every row.
        #expect(face.epoch == 8)
        #expect(face.roster == 3)
        #expect(face.skills.map(\.id) == ["3-0", "3-1"])

        // Both lists index separately, so the same id string appears in
        // both. Which one a toggle means is carried by the action name, not
        // by the id -- so these must not be deduplicated or prefixed here.
        #expect(face.mcp.map(\.id) == ["3-0"])
    }

    /// Both directions of disagreement survive decoding, separately.
    @Test func theTwoKindsOfDeviationStayApart() throws {
        let face = try #require(PersonaFace(json: faceWorn))

        let switchedOff = try #require(face.skills.first { $0.name == "reading-a-terminal" })
        #expect(switchedOff.inPersona)
        #expect(!switchedOff.enabled)
        #expect(switchedOff.isDeviation)

        let addedByHand = try #require(face.skills.first { $0.name == "extra" })
        #expect(!addedByHand.inPersona)
        #expect(addedByHand.enabled)
        #expect(addedByHand.isDeviation)

        #expect(face.deviates)
    }

    /// A slot the persona granted whose server never came up is not the
    /// persona withholding it, and the two must not decode to the same row.
    @Test func brokenIsItsOwnStateNotAnAbsentOne() throws {
        let face = try #require(PersonaFace(json: faceWorn))
        let argus = try #require(face.mcp.first)
        #expect(argus.slot == .broken)
        #expect(argus.enabled)       // granted, and still on
        #expect(!argus.isDeviation)  // nothing was changed by hand
    }

    /// A slot state this build has never heard of decodes to nothing, and
    /// nothing is drawn for it. Guessing would put a sentence about the
    /// server under a row whose state we do not actually know.
    @Test func anUnknownSlotStateIsNotGuessedAt() throws {
        let json = #"{"skills":[],"mcp":[{"id":"1-0","name":"x","enabled":true,"in_persona":true,"slot":"quarantined"}]}"#
        let face = try #require(PersonaFace(json: json))
        #expect(face.mcp.first?.slot == nil)
    }

    /// A row with no id is a row whose switch could not be sent anywhere, so
    /// it is dropped rather than drawn as a control that does nothing.
    @Test func aRowWithoutAnIdIsDropped() throws {
        let json = #"{"skills":[{"name":"nameless","enabled":true,"in_persona":true},{"id":"1-0","name":"fine","enabled":true,"in_persona":true}],"mcp":[]}"#
        let face = try #require(PersonaFace(json: json))
        #expect(face.skills.map(\.name) == ["fine"])
    }

    // MARK: Errors

    @Test func theCoresErrorTextSurvivesDecoding() throws {
        let json = #"{"skills":[],"mcp":[],"error":"personas.json:3: expected ','","error_kind":"parse"}"#
        let face = try #require(PersonaFace(json: json))
        #expect(face.errorKind == "parse")
        #expect(face.loadError == "personas.json:3: expected ','")
    }

    // MARK: The read-only inventory's four states

    @Test func eachInventoryStateDecodesToItself() throws {
        let json = #"""
        {"stale":false,"slot_budget":{"complete":false},
         "hosts":[{"key":"claude-code","plugins":["a","b"],"skills":"absent","mcp":"permission denied"}]}
        """#
        let inventory = try #require(HostInventory(json: json))

        #expect(inventory.isKnown)
        #expect(inventory.host == "claude-code")
        #expect(inventory.plugins == .read(["a", "b"]))
        #expect(inventory.skills == .absent)
        #expect(inventory.mcpServers == .failed("permission denied"))

        // A count taken while some agent's config was unreadable is a lower
        // bound, and a lower bound looks exactly like a count.
        #expect(!inventory.slotBudgetComplete)
    }

    /// A category this side does not recognise is *our* gap, so it reads as
    /// "nobody checked" rather than as "nothing installed". Defaulting the
    /// other way would turn an unknown shape into a claim about the machine.
    @Test func anUnrecognisedCategoryIsOurGapNotAnEmptyMachine() throws {
        let json = #"{"stale":false,"hosts":[{"key":"codex","plugins":{"weird":1}}]}"#
        let inventory = try #require(HostInventory(json: json))
        #expect(inventory.plugins == .unknownLocation)
        #expect(inventory.skills == .unknownLocation)
    }

    @Test func slotBudgetDefaultsToCompleteWhenNobodySaysOtherwise() throws {
        let json = #"{"stale":false,"hosts":[{"key":"codex","plugins":[]}]}"#
        let inventory = try #require(HostInventory(json: json))
        #expect(inventory.slotBudgetComplete)
        #expect(inventory.plugins == .read([]))
    }
}
