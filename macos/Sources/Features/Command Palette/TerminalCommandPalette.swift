import SwiftUI
import GhosttyKit

func sortedTerminalPaletteOptions(_ options: [CommandOption]) -> [CommandOption] {
    options.sorted { lhs, rhs in
        let lhsTitle = lhs.title.replacingOccurrences(of: ":", with: "\t")
        let rhsTitle = rhs.title.replacingOccurrences(of: ":", with: "\t")
        let comparison = lhsTitle.localizedCaseInsensitiveCompare(rhsTitle)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        if let lhsKey = lhs.sortKey, let rhsKey = rhs.sortKey {
            return lhsKey < rhsKey
        }
        return false
    }
}

struct TerminalCommandPaletteView: View {
    /// The surface that this command palette represents.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The update view model for showing update commands.
    var updateViewModel: UpdateViewModel?

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: commandOptions
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the command palette disappears we need to send focus back to the
            // surface view we were overlaid on top of. There's probably a better way
            // to handle the first responder state here but I don't know it.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// All commands available in the command palette, combining update and terminal options.
    private var commandOptions: [CommandOption] {
        var options: [CommandOption] = []
        // Updates always appear first
        options.append(contentsOf: updateOptions)

        // Sort the rest. We replace ":" with a character that sorts before space
        // so that "Foo:" sorts before "Foo Bar:". Use sortKey as a tie-breaker
        // for stable ordering when titles are equal.
        options.append(contentsOf: sortedTerminalPaletteOptions(jumpOptions + terminalOptions + hostOptions))
        return options
    }

    /// Commands for installing or canceling available updates.
    private var updateOptions: [CommandOption] {
        var options: [CommandOption] = []

        guard let updateViewModel else {
            return options
        }

        if updateViewModel.state.isInstallable {
            // We override the update available one only because we want to properly
            // convey it'll go all the way through.
            let title: String
            if case .updateAvailable = updateViewModel.state {
                title = String(localized: "Update Polter and Restart", comment: "命令面板里装更新的那一项")
            } else {
                title = updateViewModel.text
            }

            options.append(CommandOption(
                title: title,
                description: updateViewModel.description,
                leadingIcon: updateViewModel.iconName ?? "shippingbox.fill",
                badge: updateViewModel.badge,
                emphasis: true
            ) {
                (NSApp.delegate as? AppDelegate)?.updateController.viewModel.state.confirm()
            })
        }

        if updateViewModel.state.isCancellable {
            options.append(CommandOption(
                title: String(localized: "Cancel or Skip Update", comment: "命令面板：取消或跳过这次更新"),
                description: String(localized: "Dismiss the current update process", comment: "命令面板：取消或跳过更新的说明")
            ) {
                updateViewModel.state.cancel()
            })
        }

        return options
    }

    /// Custom commands from the command-palette-entry configuration.
    private var terminalOptions: [CommandOption] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        return appDelegate.ghostty.config.commandPaletteEntries
            .filter(\.isSupported)
            .map { c in
                let symbols = appDelegate.ghostty.config.keyboardShortcut(for: c.action)?.keyList
                return CommandOption(
                    title: c.title,
                    description: c.description,
                    symbols: symbols,
                    aliases: [CommandOption.actionAlias(c.action)]
                ) {
                    onAction(c.action)
                }
            }
    }

    /// The menu bar's own commands -- "Load Project…" and the rest the core
    /// has no entry for (#50) -- read from the menu bar each time, and run
    /// through it (`HostMenuCommands`). Found by the selector as words too,
    /// so "load project" finds the item in a Chinese interface.
    private var hostOptions: [CommandOption] {
        guard let appDelegate = NSApp.delegate as? AppDelegate, let mainMenu = NSApp.mainMenu else { return [] }
        let skipping: Set<ObjectIdentifier> = NSApp.servicesMenu.map { [ObjectIdentifier($0)] } ?? []
        return HostMenuCommands.entries(in: mainMenu, core: appDelegate.coreMenuItems, skipping: skipping).map { entry in
            let item = entry.item
            return CommandOption(
                title: item.title,
                description: entry.path.joined(separator: " › "),
                aliases: item.action.map { [HostMenuCommands.alias(for: $0)] } ?? []
            ) {
                HostMenuCommands.perform(item)
            }
        }
    }

    /// Commands for jumping to other terminal surfaces.
    private var jumpOptions: [CommandOption] {
        TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }

            let color = (window as? TerminalWindow)?.tabColor
            let displayColor = color != TerminalTabColor.none ? color : nil

            return controller.surfaceTree.map { surface in
                let terminalTitle = surface.title.isEmpty ? window.title : surface.title
                let displayTitle: String
                if let override = controller.titleOverride, !override.isEmpty {
                    displayTitle = override
                } else if !terminalTitle.isEmpty {
                    displayTitle = terminalTitle
                } else {
                    displayTitle = "Untitled"
                }
                let pwd = surface.pwd?.abbreviatedPath
                let subtitle: String? = if let pwd, !displayTitle.contains(pwd) {
                    pwd
                } else {
                    nil
                }

                return CommandOption(
                    title: String(format: String(localized: "Focus: %@", comment: "命令面板：跳到某个终端，%@ 是它的标题"), displayTitle),
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor?.displayColor.map { Color($0) },
                    sortKey: ObjectIdentifier(surface),
                    aliases: ["focus"]
                ) {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }

}

/// This is done to ensure that the given view is in the responder chain.
private struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
