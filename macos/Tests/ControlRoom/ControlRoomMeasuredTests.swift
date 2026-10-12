import AppKit
import Testing
@testable import Ghostty

/// Widths in the look table that have to hold real text, held to the real
/// font. The table's numbers were once worked out from a guessed character
/// width, and the guess was a pixel short.
struct ControlRoomMeasuredTests {
    typealias Look = ControlRoomLook

    /// The face a lane's name is set in (`ControlRoomListView.lane`): the
    /// system monospaced one, at the smallest size the table allows.
    private let laneFont = NSFont.monospacedSystemFont(ofSize: CGFloat(Look.Font.min), weight: .regular)

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: laneFont]).width
    }

    @Test func aLanesNameColumnHoldsThirteenCharactersAndNotFourteen() {
        let column = CGFloat(Look.Side.timeLaneLabelWidth)
        // The name that was cut on a real window, twice.
        let docs = width("web-app-docs")
        #expect(docs <= column, "web-app-docs is \(docs) wide and the column is \(column)")
        let thirteen = width("design-system")
        #expect(thirteen <= column, "thirteen characters are \(thirteen) wide and the column is \(column)")
        // What the table's own description says is cut.
        let fourteen = width("abcdefghijklmn")
        #expect(fourteen > column)
    }

    @Test func theTrackKeepsMostOfTheLane() {
        // The panel's inner width less its padding is the lane; the name
        // must leave the bar more than half of it.
        let lane = CGFloat(Look.Side.width) - 2 * CGFloat(Look.Space.frameToContent) - 2 * CGFloat(Look.Side.rowPaddingX)
        let track = ControlRoomListLayout.trackWidth(lane: lane)
        #expect(track > lane / 2, "the track is \(track) of a lane \(lane) wide")
    }
}
