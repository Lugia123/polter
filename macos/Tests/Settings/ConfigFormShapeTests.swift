import Foundation
import Testing
@testable import Ghostty

/// The settings table in the shape the core writes it now, read by the
/// type the settings window reads it with. Kept apart from
/// `ConfigFormRulesTests`, which needs the running app: this one needs
/// nothing, so it can be run wherever the sources can be compiled.
struct ConfigFormShapeTests {
    /// The table as the core has written it since the screenshot group was
    /// added: a section carries `shortcuts`, an item carries `aliases`,
    /// `on`, `off` and `choice_template`, a choice's name can be null, and
    /// there is a control (`directory`) older hosts never heard of. The
    /// first of these that this type could not read took the whole table
    /// with it, and every group of the settings window was empty.
    private static let withScreenshots = #"""
    {"main":"/c","backup":null,"errors":[],
     "sections":[{"group":"screenshot","keys":["screenshot-mouse-trigger","screenshot-directory","screenshot-agent-access"],
                  "shortcuts":[{"action":"screenshot","label":"Screenshot","summary":"Take one.","aliases":["capture"]}]}],
     "items":[
      {"key":"screenshot-mouse-trigger","group":"screenshot","label":"Mouse Trigger","summary":"S","control":"choice",
       "choices":["","cmd+shift","ctrl+shift"],"choice_labels":["Off",null,null],"choice_template":"%s + Double-Click",
       "on":null,"off":null,"aliases":["double-click"],"min":null,"max":null,"default":"cmd+shift","value":"cmd+shift",
       "doc":null,"source":{"kind":"default","path":null,"line":null},"readonly":null},
      {"key":"screenshot-directory","group":"screenshot","label":"Folder","summary":"S","control":"directory",
       "choices":null,"choice_labels":null,"choice_template":null,"on":null,"off":null,"aliases":[],
       "min":null,"max":null,"default":"","value":"","doc":null,"source":{"kind":"default","path":null,"line":null},"readonly":null},
      {"key":"screenshot-agent-access","group":"screenshot","label":"Agents","summary":"S","control":"toggle",
       "choices":null,"choice_labels":null,"choice_template":null,"on":"allow","off":"deny","aliases":[],
       "min":null,"max":null,"default":"allow","value":"allow","doc":null,"source":{"kind":"default","path":null,"line":null},"readonly":null}
     ]}
    """#

    @Test func aChoiceTheTableDoesNotNameDoesNotTakeTheTableWithIt() throws {
        let form = try #require(ConfigForm.parse(Self.withScreenshots), "the whole table failed to decode")
        #expect(form.items.count == 3)
        let trigger = try #require(form.items.first { $0.key == "screenshot-mouse-trigger" })
        #expect(trigger.choiceLabels == ["Off", nil, nil])
        // Named: its name. Not named: the value, until the host spells it.
        #expect(ConfigFormRules.choiceTitle("", of: trigger, bundle: .main) == "Off")
        #expect(ConfigFormRules.choiceTitle("cmd+shift", of: trigger, bundle: .main) == "cmd+shift")
        // A control this build does not draw is shown read-only.
        #expect(form.items.first { $0.key == "screenshot-directory" }?.control == .readonly)
        #expect(form.items.first { $0.key == "screenshot-agent-access" }?.control == .toggle)
    }
}
