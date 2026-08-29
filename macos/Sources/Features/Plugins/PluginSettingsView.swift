import SwiftUI

/// The settings form for one plugin, built from its own JSON Schema.
///
/// Generated rather than hand-written per plugin: a plugin is a directory
/// somebody can drop in, so there is no build-time list of them to write
/// screens for. What the plugin declares in `plugin.json` is what appears.
struct PluginSettingsView: View {
    let plugin: Plugin
    @State private var settings: PluginSettings
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    /// Called after a successful save, so the menu can redraw its tick.
    var onSave: (() -> Void)?

    init(plugin: Plugin, onSave: (() -> Void)? = nil) {
        self.plugin = plugin
        self.onSave = onSave

        // The schema's defaults are put in as the starting values for
        // anything nobody has set, so that what is on screen and what would
        // be saved are the same thing. Only what is missing: a value the
        // user has already chosen is never overwritten, including an empty
        // one they emptied on purpose.
        var initial = PluginSettings.load(for: plugin)
        for parameter in plugin.parameters {
            guard initial.params[parameter.name] == nil,
                  let value = parameter.defaultValue
            else { continue }
            initial.params[parameter.name] = value
        }
        _settings = State(initialValue: initial)
    }

    @ViewBuilder
    var body: some View {
        // A plugin that brings its own page gets to draw its own screen, and
        // the form below is what everything else gets. The form is not the
        // lesser of the two: a plugin with two fields should not have to
        // write a web page, and on GTK -- where a web view means linking
        // WebKitGTK -- the form is the only one there is.
        if plugin.pageURL != nil {
            PluginPage(
                plugin: plugin,
                onSave: onSave,
                onClose: { dismiss() })
                .frame(width: 640, height: 560)
        } else {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(plugin.name).font(.title2)

            // The plugin's own sentence about itself, in the reader's
            // language when it ships one. A form built out of a stranger's
            // schema is a list of fields with nothing saying what the thing
            // is for.
            if !plugin.summary.isEmpty {
                Text(plugin.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // One sentence for every plugin. There used to be a switch on
            // the kind here, with a different sentence per case and a
            // paragraph shown for archives alone -- and that was a screen
            // deciding what to show by what it had guessed the plugin was.
            // Every plugin is now a resident subscriber with the same
            // lifetime, so there is nothing left to branch on.
            Toggle(isOn: $settings.enabled) {
                Text("Let this plugin run")
            }

            // What it is handed, from its own `wants.events`.
            //
            // The phrases where this build has one, and the raw wire names
            // where it has not. Showing the raw name matters: it is what
            // keeps an event added after this build from turning into a
            // plugin that says nothing about itself, which is the shape the
            // old kind list failed in.
            subscription
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // One literal, not several joined with `+`. A concatenation is
            // an expression of type `String`, which picks `Text(verbatim:)`
            // and is never looked up in a strings table -- so a paragraph
            // written that way cannot be translated no matter how many
            // entries are added for it. Only a single literal is a
            // `LocalizedStringKey`.
            Text("It runs for as long as Polter does and is handed those events as they happen. A plugin that stops, or cannot reach where it writes, catches up afterwards rather than losing anything -- Polter's own record on disk is what it is copied from and stays the record either way. Changing this takes effect the next time Polter starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if plugin.parameters.isEmpty {
                Text("This plugin has nothing to configure.")
                    .foregroundStyle(.secondary)
            } else {
                // Laid out in the same stack as everything else rather than
                // in a `Form`. A grouped form is a scroll container that
                // sizes itself from the height it is given, and this sheet
                // gives a width only -- so it collapsed to nothing and the
                // fields were present, laid out, and zero points tall. The
                // gap between the paragraphs above and below was the form.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plugin.parameters) { parameter in
                        field(parameter)
                    }
                }
            }

            // Said once, next to the fields it applies to, rather than in
            // documentation nobody has open while typing a password in.
            Text("A value may be a reference instead of the thing itself: env:NAME, file:/path, keychain:service/account, or cmd:… for a password manager. It is resolved at the moment the plugin is called, and never stored here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.enabled && !settings.isComplete(for: plugin))
            }
        }
        .padding(20)
        .frame(width: 520)
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
            Text("This plugin subscribes to nothing, so Polter has nothing to hand it and will not start it.")
        } else {
            Text("What it is handed: \(said.joined(separator: ", "))")
        }
    }

    @ViewBuilder
    private func field(_ parameter: Plugin.Parameter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // What the schema says the value may be decides the control.
            // Everything used to be a text box, `enum` and `boolean`
            // included -- so a parameter that takes three words was a box
            // you could type anything into, and what you typed was saved.
            // The declaration was written down and then not read.
            switch parameter.control {
            case .text:
                TextField(
                    parameter.title,
                    text: Binding(
                        get: { settings.params[parameter.name] ?? "" },
                        set: { settings.params[parameter.name] = $0 }))

            case .flag:
                Toggle(parameter.title, isOn: Binding(
                    get: { settings.params[parameter.name] == "true" },
                    set: { settings.params[parameter.name] = $0 ? "true" : "false" }))

            case .choice(let choices):
                Picker(parameter.title, selection: Binding(
                    get: { settings.params[parameter.name] ?? "" },
                    set: { settings.params[parameter.name] = $0 })
                ) {
                    // What is in the file, when it is not one of the
                    // choices. Shown rather than silently corrected: a value
                    // that got in there before this menu existed, or by
                    // hand, is something the person needs to see in order to
                    // decide what to replace it with -- and rewriting it on
                    // open would change a file just because a window was
                    // opened.
                    let current = settings.params[parameter.name] ?? ""
                    if !current.isEmpty, !choices.contains(where: { $0.value == current }) {
                        Text("\(current) — not one of the choices").tag(current)
                    }

                    // An empty selection needs an entry of its own, or the
                    // menu shows a blank with no way back to it.
                    if current.isEmpty {
                        Text("Not set").tag("")
                    }

                    ForEach(choices) { choice in
                        Text(choice.value).tag(choice.value)
                    }
                }
            }

            if !parameter.help.isEmpty {
                Text(parameter.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Deliberately not a SecureField. A masked box invites typing the
            // secret in, and the value that belongs here is a reference the
            // user needs to read back and check.
            if parameter.looksSecret {
                Text("Prefer a reference here so the secret stays out of this file.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func save() {
        do {
            try settings.save(key: plugin.key)
            onSave?()
            dismiss()
        } catch {
            // Kept on screen rather than logged away: the user is looking at
            // the thing that failed and can act on it.
            self.error = String(
                localized: "Could not save: \(error.localizedDescription)",
                comment: "插件设置保存失败")
        }
    }
}
