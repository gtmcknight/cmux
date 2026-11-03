public import CmuxNextActions
public import CmuxNextDesignTokens
public import CmuxNextSettings
public import CmuxNextSidebar

/// Every action this package binds, from one call at the composition root (AppActions): archive,
/// auto-archive, the compact workspace list toggle and the Sidebar States Playground.
@MainActor
public struct SidebarActionSet {
    private let host: any SidebarArchiveHost
    private let autoArchive: AutoArchiveCoordinator
    private let settings: @MainActor () -> SettingsController?
    private let themeColors: @MainActor () -> [String: ThemeFileColors]

    /// - Parameter themeColors: Every theme file's colors by name, for the Sidebar States Playground's sheets
    ///   (``SidebarStatesPlaygroundAction``); none leaves them in the window's theme.
    public init(host: any SidebarArchiveHost, autoArchive: AutoArchiveCoordinator, settings: @escaping @MainActor () -> SettingsController?,
                themeColors: @escaping @MainActor () -> [String: ThemeFileColors] = { [:] }) {
        self.host = host
        self.autoArchive = autoArchive
        self.settings = settings
        self.themeColors = themeColors
    }

    public func bind(into registry: ActionRegistry) {
        SidebarArchiveActions(host: host).bind(into: registry)
        AutoArchiveActions(coordinator: autoArchive, host: host).bind(into: registry)
        SidebarCompactListToggle(settings: settings).bind(into: registry)
        SidebarStatesPlaygroundAction(themeColors: themeColors).bind(into: registry)
    }
}
