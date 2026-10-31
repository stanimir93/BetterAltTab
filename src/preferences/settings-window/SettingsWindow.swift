import Cocoa

/// Settings: one fixed-width page with a header, a few sections of rows, and a footer. Every control
/// writes its preference through `Preferences`, so the change applies live like any other, and
/// re-reads it when the preference changes elsewhere. Preferences with no control here keep their
/// stored value. The window is rebuilt on each open and released on close.
class SettingsWindow: NSWindow {
    static var shared: SettingsWindow?
    private static let width = CGFloat(500)
    private static let horizontalMargin = CGFloat(24)
    /// Clears the traffic lights, which float over the page's top edge.
    private static let topMargin = CGFloat(40)
    private static let bottomMargin = CGFloat(20)
    private static let sectionSpacing = CGFloat(20)
    /// Room left around the window when the page is taller than the screen and has to scroll.
    private static let screenMargin = CGFloat(80)
    private static let delayFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.numberFormatter = NumberFormatter()
        return formatter
    }()

    override var canBecomeKey: Bool { SecondaryWindows.canBecomeKey }

    private let scrollView = NSScrollView()
    private let headerSubtitle = NSTextField(labelWithString: "")
    /// What re-reads the controls showing a preference key, run by `preferenceChanged`: a key can change
    /// from outside this page (the menubar icon dragged off the menubar, a conflict dialog unassigning a
    /// shortcut), and the control must follow.
    private var refreshers = [String: [() -> Void]]()

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        delegate = self
        applySecondaryWindowChrome(NSLocalizedString("Settings", comment: "Settings window title"))
        isMovableByWindowBackground = true
        setupContent()
        Self.shared = self
    }

    func preferenceChanged(_ key: String) {
        refreshers[key]?.forEach { $0() }
    }

    override func close() {
        hideAppIfLastWindowIsClosed()
        super.close()
    }

    private func setupContent() {
        let document = FlippedView()
        let page = makePage()
        document.translatesAutoresizingMaskIntoConstraints = false
        page.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(page)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        contentView = scrollView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalToConstant: Self.width),
            page.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.topMargin),
            page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Self.bottomMargin),
            page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.horizontalMargin),
            page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Self.horizontalMargin),
        ])
        setContentSize(NSSize(width: Self.width, height: min(document.fittingSize.height, maxContentHeight())))
    }

    private func maxContentHeight() -> CGFloat {
        let screen = NSScreen.preferred
        return screen.visibleFrame.height - Self.screenMargin
    }

    private func makePage() -> NSView {
        let views = [header(), shortcutSection(), windowsSection(), appearanceSection(), generalSection(), footer()]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.sectionSpacing
        views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    // MARK: - Header and footer

    private func header() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 52).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let name = NSTextField(labelWithString: App.name)
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        headerSubtitle.textColor = .secondaryLabelColor
        refreshSubtitle()
        let text = NSStackView(views: [name, headerSubtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let stack = NSStackView(views: [icon, text])
        stack.alignment = .centerY
        stack.spacing = 14
        return stack
    }

    private func refreshSubtitle() {
        let keys = ["holdShortcut", "nextWindowShortcut"].map { Preferences.shortcut($0)?.keyEquivalent ?? "" }.joined()
        let format = NSLocalizedString("Switch between windows with %@", comment: "Settings header. %@ is a shortcut, like ⌘⇥")
        headerSubtitle.stringValue = keys.isEmpty ? Self.versionText() : String(format: format, keys)
    }

    private func footer() -> NSView {
        let version = NSTextField(labelWithString: Self.versionText())
        version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        version.textColor = .secondaryLabelColor
        let github = NSButton(title: "", target: nil, action: nil)
        github.isBordered = false
        github.attributedTitle = NSAttributedString(string: "GitHub", attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        github.toolTip = App.repository
        github.onAction = { _ in NSWorkspace.shared.open(URL(string: App.repository)!) }
        let quit = NSButton(title: String(format: NSLocalizedString("Quit %@", comment: "%@ is AltTab"), App.name), target: nil, action: #selector(NSApplication.terminate(_:)))
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView()
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: SettingsCard.rowHorizontalPadding, bottom: 0, right: 0)
        stack.setViews([version], in: .leading)
        stack.setViews([github, quit], in: .trailing)
        return stack
    }

    private static func versionText() -> String {
        NSLocalizedString("Version", comment: "") + " " + App.version
    }

    // MARK: - Sections

    private func shortcutSection() -> NSView {
        let rows = [
            recorderRow(NSLocalizedString("Hold", comment: ""), "holdShortcut", clearable: false),
            recorderRow(NSLocalizedString("Select next window", comment: ""), "nextWindowShortcut", clearable: true),
            recorderRow(NSLocalizedString("Select previous window", comment: ""), "previousWindowShortcut", clearable: true),
        ]
        ControlsTab.initializeShortcutRecorderState(0)
        ControlsTab.shortcutControls["previousWindowShortcut"].map { ControlsTab.shortcutChangedCallback($0) }
        return SettingsCard.section(NSLocalizedString("Shortcut", comment: ""), rows)
    }

    /// Shortcut 1's filters. The other shortcuts, and the gesture, keep theirs.
    private func windowsSection() -> NSView {
        let showHow = ShowHowPreference.allCases
        return SettingsCard.section(NSLocalizedString("Windows", comment: "Settings section: which windows the switcher lists"), [
            popupRow(NSLocalizedString("Show minimized windows", comment: ""), "showMinimizedWindows", showHow),
            popupRow(NSLocalizedString("Show hidden windows", comment: ""), "showHiddenWindows", showHow),
            popupRow(NSLocalizedString("Show fullscreen windows", comment: ""), "showFullscreenWindows", showHow.filter { $0 != .showAtTheEnd }),
            popupRow(NSLocalizedString("Show apps with no open window", comment: ""), "showWindowlessApps", showHow),
            popupRow(NSLocalizedString("Show windows from Spaces", comment: ""), "spacesToShow", SpacesToShowPreference.allCases),
            popupRow(NSLocalizedString("Show windows from screens", comment: ""), "screensToShow", ScreensToShowPreference.allCases),
        ])
    }

    private func appearanceSection() -> NSView {
        SettingsCard.section(NSLocalizedString("Appearance", comment: ""), [
            popupRow(NSLocalizedString("Theme", comment: ""), "appearanceTheme", [AppearanceThemePreference.system, .light, .dark]),
            delayRow(),
        ])
    }

    private func generalSection() -> NSView {
        SettingsCard.section(NSLocalizedString("General", comment: ""), [
            switchRow(NSLocalizedString("Start at login", comment: ""), "startAtLogin"),
            switchRow(NSLocalizedString("Menubar icon", comment: ""), "menubarIconShown"),
        ])
    }

    // MARK: - Rows

    private func recorderRow(_ title: String, _ key: String, clearable: Bool) -> NSView {
        let recorder = ControlsTab.makeRecorder(key, clearable: clearable)
        observe(key) { [weak self] in self?.syncRecorders() }
        return SettingsCard.row(title, [recorder])
    }

    /// The recorders show what is stored, and the next-window recorder can't take the hold's modifiers.
    private func syncRecorders() {
        ControlsTab.shortcutControls.forEach { key, recorder in
            let stored = Preferences.shortcut(key)
            if recorder.objectValue != stored { recorder.objectValue = stored }
        }
        ControlsTab.shortcutControls["nextWindowShortcut"]?.restrictModifiers(Preferences.shortcut("holdShortcut")?.modifierFlags ?? [])
        refreshSubtitle()
    }

    /// `cases` in display order; the stored value is each case's index in its enum, as everywhere else.
    private func popupRow<T: MacroPreference & CaseIterable & Equatable>(_ title: String, _ key: String, _ cases: [T]) -> NSView {
        let popup = PopupButtonLikeSystemSettings()
        popup.addItems(withTitles: cases.map { $0.localizedString })
        let sync: () -> Void = { [weak popup] in
            popup?.selectItem(at: cases.firstIndex(of: CachedUserDefaults.macroPref(key, Array(T.allCases))) ?? 0)
        }
        sync()
        popup.onAction = { [weak self] control in
            self?.write(key, cases[(control as! NSPopUpButton).indexOfSelectedItem].indexAsString)
        }
        observe(key, sync)
        return SettingsCard.row(title, [popup])
    }

    private func switchRow(_ title: String, _ key: String) -> NSView {
        let toggle = NSSwitch()
        let sync: () -> Void = { [weak toggle] in toggle?.state = CachedUserDefaults.bool(key) ? .on : .off }
        sync()
        toggle.onAction = { [weak self] control in
            self?.write(key, String((control as! NSSwitch).state == .on))
        }
        observe(key, sync)
        return SettingsCard.row(title, [toggle])
    }

    /// `windowDisplayDelay`, in the 50ms steps the slider's tick marks allow.
    private func delayRow() -> NSView {
        let key = "windowDisplayDelay"
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 900, target: nil, action: nil)
        slider.numberOfTickMarks = 19
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let sync: () -> Void = { [weak slider, weak value] in
            let delay = Preferences.windowDisplayDelayInMs
            slider?.integerValue = delay
            value?.stringValue = Self.delayFormatter.string(from: Measurement(value: Double(delay), unit: Unit(symbol: "ms")))
        }
        sync()
        slider.onAction = { [weak self] control in
            self?.write(key, String(format: "%.0f", control.doubleValue))
        }
        observe(key, sync)
        return SettingsCard.row(NSLocalizedString("Delay before the switcher appears", comment: ""), [slider, value])
    }

    private func observe(_ key: String, _ refresh: @escaping () -> Void) {
        refreshers[key, default: []].append(refresh)
    }

    private func write(_ key: String, _ value: String) {
        guard UserDefaults.standard.string(forKey: key) != value else { return }
        Preferences.set(key, value)
    }

#if DEBUG
    func qaCloseWithoutHidingApp() {
        super.close()
    }
#endif
}

extension SettingsWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Defer to the next runloop tick: tearing down view trees, removing observers,
        // and dropping the last strong ref to `self` while AppKit is still inside its own
        // close machinery causes objc_release crashes on re-entry.
        DispatchQueue.main.async { [weak self] in
            guard let self, SettingsWindow.shared === self else { return }
            ControlsTab.forgetRecorders()
            SettingsWindow.shared = nil
        }
    }
}

#if DEBUG
extension SettingsWindow {
    /// For `QaSurfaces`: the page scrolled to its top, without scrollers.
    func qaShow() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        qaHideScrollers()
    }

    func qaHideScrollers() {
        scrollView.verticalScroller?.alphaValue = 0
    }

    func qaPager() -> QaSurfaces.Pager {
        QaSurfaces.Pager(scrollView: scrollView, top: 0, bottom: scrollView.documentView?.frame.height ?? 0)
    }

    static func qaDiscard() {
        guard let window = shared else { return }
        if let sheet = window.attachedSheet {
            sheet.animationBehavior = .none
            QaSheetAnimation.disable(on: sheet)
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
        window.delegate = nil
        window.qaCloseWithoutHidingApp()
        ControlsTab.forgetRecorders()
        shared = nil
    }
}
#endif
