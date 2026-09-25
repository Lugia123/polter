import AppKit

extension NSMenuItem {
    /// Whether this system wants images on menu items at all.
    ///
    /// Split out of `setImageIfDesired` so the decision can be *named*
    /// instead of only living inside an `#available`. A machine that is on
    /// macOS 26 can never take the other branch, so a check written against
    /// `setImageIfDesired` alone says nothing whatever about what older
    /// systems get -- and "no icons at all" is the *correct* answer there,
    /// which means it is an answer worth being able to assert.
    static var menuItemImagesAreDesired: Bool {
        // We only set on macOS 26 when icons on menu items became the norm.
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Sets the image property from a symbol if we want images on our menu items.
    func setImageIfDesired(systemSymbolName symbol: String) {
        setImage(systemSymbolName: symbol, desired: Self.menuItemImagesAreDesired)
    }

    /// The half of `setImageIfDesired` that asks the OS nothing.
    ///
    /// Callers in the app pass `menuItemImagesAreDesired`; a test passes
    /// both values. Same statements either way -- the version check is the
    /// only thing that is not exercised on both sides, and it is one line
    /// whose true side is what this machine returns.
    func setImage(systemSymbolName symbol: String, desired: Bool) {
        if desired {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
    }
}
