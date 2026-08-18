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
        _settings = State(initialValue: PluginSettings.load(key: plugin.key))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(plugin.name).font(.title2)

            Toggle(isOn: $settings.enabled) {
                Text("Send notifications through this plugin")
            }

            if plugin.parameters.isEmpty {
                Text("This plugin has nothing to configure.")
                    .foregroundStyle(.secondary)
            } else {
                Form {
                    ForEach(plugin.parameters) { parameter in
                        field(parameter)
                    }
                }
                .formStyle(.grouped)
            }

            // Said once, next to the fields it applies to, rather than in
            // documentation nobody has open while typing a password in.
            Text("A value may be a reference instead of the thing itself: "
                 + "env:NAME, file:/path, keychain:service/account, or "
                 + "cmd:… for a password manager. It is resolved when the "
                 + "notification is sent, and never stored here.")
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

    private func field(_ parameter: Plugin.Parameter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                parameter.title,
                text: Binding(
                    get: { settings.params[parameter.name] ?? "" },
                    set: { settings.params[parameter.name] = $0 }))

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
