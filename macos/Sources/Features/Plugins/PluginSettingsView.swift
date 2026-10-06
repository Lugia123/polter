import SwiftUI

/// The settings form for one plugin, built from its own JSON Schema: the
/// Settings tab of the Plugins section (settings.md §5.2).
///
/// Generated rather than hand-written per plugin: a plugin is a directory
/// somebody can drop in, so there is no build-time list of them to write
/// screens for. What the plugin declares in `plugin.json` is what appears.
///
/// It edits a draft and saves nothing: Save and Revert are the settings
/// window's, in its bottom band, and saving goes through the core
/// (`PluginCore.configure`). It used to be a window of its own with its own
/// buttons, one per plugin.
struct PluginSettingsForm: View {
    let plugin: Plugin
    @Binding var settings: PluginSettings

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
            // What it is handed, from its own `wants.events`.
            //
            // The phrases where this build has one, and the raw wire names
            // where it has not. Showing the raw name matters: it is what
            // keeps an event added after this build from turning into a
            // plugin that says nothing about itself, which is the shape the
            // old kind list failed in.
            subscription
                .font(SettingsFont.minimum)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // One literal, not several joined with `+`. A concatenation is
            // an expression of type `String`, which picks `Text(verbatim:)`
            // and is never looked up in a strings table -- so a paragraph
            // written that way cannot be translated no matter how many
            // entries are added for it. Only a single literal is a
            // `LocalizedStringKey`.
            Text(String(localized: "It runs for as long as Polter does and is handed those events as they happen. A plugin that stops, or cannot reach where it writes, catches up afterwards rather than losing anything -- Polter's own record on disk is what it is copied from and stays the record either way.", comment: "插件设置"))
                .font(SettingsFont.minimum)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if plugin.parameters.isEmpty {
                Text(String(localized: "This plugin has nothing to configure.", comment: "插件设置"))
                    .foregroundStyle(.secondary)
                    .padding(.top, SettingsLayout.rowGap)
            } else {
                // Laid out in a stack rather than a `Form`: a grouped form
                // is a scroll container that sizes itself from the height it
                // is given, and inside another scroll view it collapses to
                // nothing.
                VStack(alignment: .leading, spacing: SettingsLayout.rowGap * 1.5) {
                    ForEach(plugin.parameters) { parameter in
                        field(parameter)
                    }
                }
                .padding(.top, SettingsLayout.rowGap)
            }

            // Said once, next to the fields it applies to, rather than in
            // documentation nobody has open while typing a password in.
            formControl {
                Text(String(localized: "A value may be a reference instead of the thing itself: env:NAME, file:/path, keychain:service/account, or cmd:… for a password manager. It is resolved at the moment the plugin is called, and never stored here.", comment: "插件设置"))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, SettingsLayout.rowGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the plugin subscribes to, said in a line.
    ///
    /// A phrase per known event and the wire name for anything else, so a
    /// build that has never heard of an event still shows that the plugin
    /// asked for it. Nothing at all when the manifest declares no events:
    /// the core hands such a plugin nothing and does not start it, and
    /// saying so is more use than an empty list.
    @ViewBuilder
    private var subscription: some View {
        // Both halves come from the one table on `Plugin`; there is no
        // second list of event names on this side to fall out of step.
        let said = plugin.roles + plugin.unrecognisedEvents

        if said.isEmpty {
            Text(String(localized: "This plugin subscribes to nothing, so Polter has nothing to hand it and will not start it.", comment: "插件设置"))
        } else {
            Text(String(localized: "What it is handed: \(said.joined(separator: ", "))", comment: "插件设置"))
        }
    }

    @ViewBuilder
    private func field(_ parameter: Plugin.Parameter) -> some View {
        // The title in the label column, the control and everything said
        // about it in the control column (settings.md §2.3a), checkboxes and
        // pop-ups included.
        VStack(alignment: .leading, spacing: SettingsLayout.rowGap / 2) {
            formRow(parameter.required ? "\(parameter.title) *" : parameter.title) {
                control(parameter)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !parameter.help.isEmpty {
                formControl {
                    Text(parameter.help)
                        .font(SettingsFont.minimum)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Deliberately not a SecureField. A masked box invites typing the
            // secret in, and the value that belongs here is a reference the
            // user needs to read back and check.
            if parameter.looksSecret {
                formControl {
                    Text(String(localized: "Prefer a reference here so the secret stays out of this file.", comment: "插件设置"))
                        .font(SettingsFont.minimum)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// What the schema says the value may be decides the control.
    /// Everything used to be a text box, `enum` and `boolean` included -- so
    /// a parameter that takes three words was a box you could type anything
    /// into, and what you typed was saved. The declaration was written down
    /// and then not read.
    @ViewBuilder
    private func control(_ parameter: Plugin.Parameter) -> some View {
        switch parameter.control {
        case .text:
            TextField(
                parameter.defaultValue ?? "",
                text: Binding(
                    get: { settings.params[parameter.name] ?? "" },
                    set: { settings.params[parameter.name] = $0 }))
                .textFieldStyle(.roundedBorder)

        case .flag:
            Toggle("", isOn: Binding(
                get: { settings.params[parameter.name] == "true" },
                set: { settings.params[parameter.name] = $0 ? "true" : "false" }))
                .labelsHidden()

        case .choice(let choices):
            Picker("", selection: Binding(
                get: { settings.params[parameter.name] ?? "" },
                set: { settings.params[parameter.name] = $0 })
            ) {
                // What is in the file, when it is not one of the choices.
                // Shown rather than silently corrected: a value that got in
                // there before this menu existed, or by hand, is something
                // the person needs to see in order to decide what to replace
                // it with -- and rewriting it on open would change a file
                // just because a window was opened.
                let current = settings.params[parameter.name] ?? ""
                if !current.isEmpty, !choices.contains(where: { $0.value == current }) {
                    Text(String(localized: "\(current) — not one of the choices", comment: "插件设置")).tag(current)
                }

                // An empty selection needs an entry of its own, or the menu
                // shows a blank with no way back to it.
                if current.isEmpty {
                    Text(String(localized: "Not set", comment: "插件设置")).tag("")
                }

                ForEach(choices) { choice in
                    Text(choice.value).tag(choice.value)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}
