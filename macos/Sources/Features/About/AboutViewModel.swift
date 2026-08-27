import Combine

class AboutViewModel: ObservableObject {
    @Published var currentIcon: Ghostty.MacOSIcon?
    @Published var isHovering: Bool = false

    private var timerCancellable: AnyCancellable?

    /// Deliberately empty.
    ///
    /// Upstream cycles the About window through Ghostty's nine official icon
    /// variants. Polter has one icon of its own, and showing somebody else's
    /// nine in the window that says what this program is was the plainest
    /// leftover of the rename: you opened About and watched Ghostty's ghost
    /// go past. With nothing here `currentIcon` stays nil, and the view
    /// falls back to the icon the application is actually running under.
    ///
    /// The list rather than the mechanism, so that a future set of Polter
    /// variants only has to be listed here.
    private let icons: [Ghostty.MacOSIcon] = []

    func startCyclingIcons() {
        guard !icons.isEmpty else { return }
        timerCancellable = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !isHovering else { return }
                advanceToNextIcon()
            }
    }

    func stopCyclingIcons() {
        timerCancellable = nil
        currentIcon = nil
    }

    func advanceToNextIcon() {
        guard !icons.isEmpty else { return }
        let currentIndex = currentIcon.flatMap(icons.firstIndex(of:)) ?? 0
        let nextIndex = icons.indexWrapping(after: currentIndex)
        currentIcon = icons[nextIndex]
    }
}
