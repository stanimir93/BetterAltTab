import Cocoa

/// A Dock icon under the pointer. `frame` is top-left global (Quartz), like `Window.position`, read when the
/// icon was hovered. An auto-hiding Dock may still be sliding in at that point, see `DockHoverEvents.settled`.
struct DockItem: Equatable {
    let appUrl: URL
    let frame: CGRect
    let icon: AXUIElement

    /// Same icon; the frame may differ.
    static func == (a: DockItem, b: DockItem) -> Bool { a.appUrl == b.appUrl && CFEqual(a.icon, b.icon) }
}

/// Reports which Dock icon the pointer is over. The Dock's single AXList posts
/// AXSelectedChildrenChanged each time the hovered icon changes, and once more with no selection when the
/// pointer leaves the Dock; its AXSelectedChildren is the hovered icon. Everything here runs on
/// `missionControlThread`, which `DockEvents` already uses for the Dock: these are IPC calls to the Dock.
class DockHoverEvents {
    private static var observer: AXObserver?
    private static let maxAttempts = 10

    static func observe(_ dockPid: pid_t) {
        BackgroundWork.missionControlThread.async { subscribe(dockPid, 1) }
    }

    /// The Dock's AXList can be missing for a moment right after the Dock (re)launches, hence the retries.
    private static func subscribe(_ dockPid: pid_t, _ attempt: Int) {
        let dock = AXUIElementCreateApplication(dockPid)
        AXUIElementSetMessagingTimeout(dock, 1)
        guard let list = dockList(dock) else {
            guard attempt < maxAttempts else { Logger.warning { "Dock list not found; Dock previews are off" }; return }
            BackgroundWork.missionControlThread.asyncAfter(1) { subscribe(dockPid, attempt + 1) }
            return
        }
        stopObserving()
        var newObserver: AXObserver?
        guard AXObserverCreate(dockPid, handleEvent, &newObserver) == .success, let newObserver,
              AXObserverAddNotification(newObserver, list, kAXSelectedChildrenChangedNotification as CFString, nil) == .success else {
            Logger.warning { "could not observe Dock hover" }
            return
        }
        CFRunLoopAddSource(BackgroundWork.missionControlThread.runLoop, AXObserverGetRunLoopSource(newObserver), .commonModes)
        observer = newObserver
        Logger.debug { "observing Dock hover" }
    }

    private static func stopObserving() {
        guard let observer else { return }
        CFRunLoopRemoveSource(BackgroundWork.missionControlThread.runLoop, AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    private static func dockList(_ dock: AXUIElement) -> AXUIElement? {
        let children: [AXUIElement]? = attribute(dock, kAXChildrenAttribute)
        return children?.first { (attribute($0, kAXRoleAttribute) as String?) == kAXListRole }
    }

    private static let handleEvent: AXObserverCallback = { _, list, _, _ in
        let item = hoveredItem(list)
        DispatchQueue.main.async { DockPreview.hovered(item) }
    }

    /// nil for anything but a running or pinned app's icon: folders, the Trash, minimized windows, separators.
    private static func hoveredItem(_ list: AXUIElement) -> DockItem? {
        guard let selected: [AXUIElement] = attribute(list, kAXSelectedChildrenAttribute), let icon = selected.first,
              (attribute(icon, kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
              let url: URL = attribute(icon, kAXURLAttribute),
              let frame = frame(icon) else { return nil }
        return DockItem(appUrl: url, frame: frame, icon: icon)
    }

    /// `item` with its icon's current frame, delivered on the main thread. An auto-hiding Dock reports the
    /// hovered icon as soon as the pointer touches the screen edge, while the Dock is still sliding in, so the
    /// frame read then is off by up to the Dock's height.
    static func settled(_ item: DockItem, _ completion: @escaping (DockItem) -> Void) {
        BackgroundWork.missionControlThread.async {
            let current = frame(item.icon).map { DockItem(appUrl: item.appUrl, frame: $0, icon: item.icon) } ?? item
            DispatchQueue.main.async { completion(current) }
        }
    }

    private static func frame(_ icon: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(icon, kAXPositionAttribute),
              let size: AXValue = attribute(icon, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }
}

/// Windows-style taskbar previews: hovering an app's Dock icon shows its windows; clicking one focuses it.
/// Main thread only.
enum DockPreview {
    static let showDelay = 0.3
    static let hideDelay = 0.25
    /// The Dock's slide-in animation, after which its icons stop moving.
    static let dockSettleDelay = 0.35
    private static var panel: DockPreviewPanel?
    private static var item: DockItem?
    private static var shownPid: pid_t?
    private static var showWork: DispatchWorkItem?
    private static var hideWork: DispatchWorkItem?
    private static var monitors = [Any]()

    static var isVisible: Bool { panel?.isVisible ?? false }

    static func hovered(_ newItem: DockItem?) {
        guard Preferences.dockPreviews, !SwitcherSession.isActive else { hideNow(); return }
        guard let newItem, let app = application(newItem.appUrl) else {
            item = nil
            showWork?.cancel()
            scheduleHideIfPointerLeft()
            return
        }
        item = newItem
        hideWork?.cancel()
        if isVisible {
            show(app, newItem)
        } else {
            scheduleShow(app, newItem)
        }
    }

    static func hideNow() {
        showWork?.cancel()
        hideWork?.cancel()
        item = nil
        shownPid = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel?.clear()
        DockAutohideHold.end()
    }

    static func thumbnailUpdated(_ window: Window) {
        guard isVisible, window.application.pid == shownPid else { return }
        panel?.refreshThumbnail(window)
    }

    static func focus(_ window: Window) {
        hideNow()
        window.focus()
    }

    static func close(_ window: Window) {
        window.close()
        guard let panel, let item else { return }
        let remaining = panel.windows.filter { $0 !== window }
        guard !remaining.isEmpty else { hideNow(); return }
        layout(remaining, item)
    }

    static func pointerEnteredPanel() {
        hideWork?.cancel()
    }

    static func pointerExitedPanel() {
        scheduleHideIfPointerLeft()
    }

    private static func scheduleShow(_ app: Application, _ newItem: DockItem) {
        showWork?.cancel()
        let work = DispatchWorkItem {
            guard item == newItem else { return }
            DockHoverEvents.settled(newItem) { settled in
                guard item == settled else { return }
                item = settled
                show(app, settled)
            }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    private static func show(_ app: Application, _ newItem: DockItem) {
        let windows = previewableWindows(app)
        guard !windows.isEmpty else { hideNow(); return }
        if shownPid != app.pid {
            WindowThumbnails.refreshAsync(windows, .refreshUiAfterExternalEvent, force: true)
        }
        shownPid = app.pid
        layout(windows, newItem)
        installMonitorsIfNeeded()
        holdDockIfNeeded()
    }

    /// The first time the panel opens, the Dock may not have finished sliding in: hold it on screen, then
    /// move the panel to where the icon ended up.
    private static func holdDockIfNeeded() {
        guard !DockAutohideHold.isHolding else { return }
        DockAutohideHold.begin()
        guard DockAutohideHold.isHolding else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + dockSettleDelay) {
            guard isVisible, let current = item else { return }
            DockHoverEvents.settled(current) { settled in
                guard isVisible, item == settled, settled.frame != current.frame, let panel else { return }
                item = settled
                layout(panel.windows, settled)
            }
        }
    }

    private static func layout(_ windows: [Window], _ newItem: DockItem) {
        let panel = panel ?? DockPreviewPanel()
        self.panel = panel
        let icon = cocoaFrame(newItem.frame)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: icon.midX, y: icon.midY)) } ?? NSScreen.main ?? NSScreen.screens[0]
        let edge = DockPreviewLayout.edge(icon, screen.frame)
        let vertical = edge != .bottom
        let available = (vertical ? screen.visibleFrame.height : screen.visibleFrame.width) - DockPreviewLayout.screenMargin * 2
        let thumbnails = DockPreviewLayout.thumbnailSizes(windows.map { aspect($0) }, maxLength: available, vertical: vertical)
        let size = DockPreviewLayout.panelSize(thumbnails, vertical: vertical)
        let origin = DockPreviewLayout.origin(size, icon: icon, edge: edge,
                                              visibleFrame: screen.visibleFrame.insetBy(dx: DockPreviewLayout.screenMargin, dy: DockPreviewLayout.screenMargin))
        panel.show(windows, thumbnails, vertical: vertical, frame: CGRect(origin: origin, size: size))
        panel.bridge = DockPreviewLayout.bridge(icon: icon, panel: panel.frame, edge: edge)
    }

    /// The same windows the switcher would list for this app, minimized ones included, minus inactive tabs.
    private static func previewableWindows(_ app: Application) -> [Window] {
        Windows.list.filter { $0.application === app && !$0.isWindowlessApp && $0.cgWindowId != nil && !$0.isTabbed && !$0.isPhantom }
    }

    private static func application(_ url: URL) -> Application? {
        let path = normalized(url)
        return Applications.list.first { $0.bundleURL.map { normalized($0) } == path }
    }

    private static func normalized(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func aspect(_ window: Window) -> CGFloat {
        guard let size = window.thumbnailArea?.size ?? window.size, size.height > 0 else { return 16 / 10 }
        return size.width / size.height
    }

    /// Quartz (top-left of the primary screen) to Cocoa (bottom-left).
    private static func cocoaFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: NSScreen.screens[0].frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func pointerIsInside() -> Bool {
        guard let panel else { return false }
        let pointer = NSEvent.mouseLocation
        return panel.frame.contains(pointer) || panel.bridge.contains(pointer)
    }

    private static func scheduleHideIfPointerLeft() {
        guard isVisible, !pointerIsInside() else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem {
            guard !pointerIsInside() else { return }
            hideNow()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    /// Global monitors only see events sent to other apps, so the panel's own tracking area covers it.
    /// Installed only while the panel shows.
    private static func installMonitorsIfNeeded() {
        guard monitors.isEmpty else { return }
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in
            if item == nil { scheduleHideIfPointerLeft() }
        }) { monitors.append(moved) }
        if let clicked = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { _ in
            hideNow()
        }) { monitors.append(clicked) }
    }
}

class DockPreviewPanel: NSPanel {
    private let background = NSVisualEffectView()
    private var tiles = [DockPreviewTile]()
    /// Cocoa frame of the icon stretched to the panel; the pointer may cross it without hiding the panel.
    var bridge = CGRect.zero
    var windows: [Window] { tiles.compactMap { $0.previewed } }

    override var canBecomeKey: Bool { false }

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        applyFloatingPanelChrome()
        level = .popUpMenu
        hasShadow = true
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer!.cornerRadius = 12
        background.layer!.masksToBounds = true
        contentView = background
        background.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { DockPreview.pointerEnteredPanel() }

    override func mouseExited(with event: NSEvent) { DockPreview.pointerExitedPanel() }

    func show(_ windows: [Window], _ thumbnails: [CGSize], vertical: Bool, frame: CGRect) {
        setFrame(frame, display: false)
        clear()
        var cursor = CGPoint(x: DockPreviewLayout.padding, y: frame.height - DockPreviewLayout.padding)
        for (window, thumbnail) in zip(windows, thumbnails) {
            let size = DockPreviewLayout.tileSize(thumbnail)
            let tile = DockPreviewTile(window, thumbnail)
            tile.frame = CGRect(x: cursor.x, y: vertical ? cursor.y - size.height : DockPreviewLayout.padding, width: size.width, height: size.height)
            background.addSubview(tile)
            tiles.append(tile)
            if vertical {
                cursor.y -= size.height + DockPreviewLayout.spacing
            } else {
                cursor.x += size.width + DockPreviewLayout.spacing
            }
        }
        if !isVisible { orderFrontRegardless() }
    }

    func refreshThumbnail(_ window: Window) {
        tiles.first { $0.previewed === window }?.refreshThumbnail()
    }

    func clear() {
        tiles.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
    }
}

class DockPreviewTile: NSView {
    private(set) weak var previewed: Window?
    private let thumbnailSlot: CGSize
    private let thumbnail = LightImageView()
    private let fallbackIcon = NSImageView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isHovered = false { didSet { updateHighlight() } }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    init(_ window: Window, _ thumbnailSlot: CGSize) {
        self.previewed = window
        self.thumbnailSlot = thumbnailSlot
        super.init(frame: CGRect(origin: .zero, size: DockPreviewLayout.tileSize(thumbnailSlot)))
        wantsLayer = true
        layer!.cornerRadius = 8
        setupHeader(window)
        setupThumbnail(window)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolTip = title.stringValue
    }

    private func setupHeader(_ window: Window) {
        let inset = DockPreviewLayout.tileInset
        let headerY = bounds.height - inset - DockPreviewLayout.titleHeight
        icon.frame = CGRect(x: inset, y: headerY + 3, width: 16, height: 16)
        icon.image = window.icon.map { NSImage(cgImage: $0, size: NSSize(width: 16, height: 16)) }
        title.stringValue = window.title.isEmpty ? (window.application.localizedName ?? "") : window.title
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.frame = CGRect(x: inset + 22, y: headerY + 2, width: bounds.width - inset * 2 - 22 - 20, height: 17)
        closeButton.frame = CGRect(x: bounds.width - inset - 18, y: headerY + 2, width: 18, height: 18)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: NSLocalizedString("Close window", comment: ""))
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.isHidden = true
        addSubviews([icon, title, closeButton])
    }

    private func setupThumbnail(_ window: Window) {
        fallbackIcon.imageScaling = .scaleProportionallyUpOrDown
        fallbackIcon.image = window.icon.map { NSImage(cgImage: $0, size: NSSize(width: 64, height: 64)) }
        let side = min(64, thumbnailSlot.height * 0.6)
        let slot = slotRect()
        fallbackIcon.frame = CGRect(x: slot.midX - side / 2, y: slot.midY - side / 2, width: side, height: side)
        addSubviews([fallbackIcon, thumbnail])
        refreshThumbnail()
    }

    func refreshThumbnail() {
        guard let window = previewed, let contents = window.thumbnail, let size = window.thumbnailArea?.size ?? contents.size() else {
            thumbnail.isHidden = true
            fallbackIcon.isHidden = false
            return
        }
        let fitted = DockPreviewLayout.fit(size, in: slotRect())
        thumbnail.updateContents(contents, fitted.size)
        thumbnail.frame.origin = fitted.origin
        thumbnail.isHidden = false
        fallbackIcon.isHidden = true
    }

    private func slotRect() -> CGRect {
        CGRect(origin: CGPoint(x: DockPreviewLayout.tileInset, y: DockPreviewLayout.tileInset), size: thumbnailSlot)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard let window = previewed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        DockPreview.focus(window)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        closeWindow()
    }

    @objc private func closeWindow() {
        guard let window = previewed else { return }
        DockPreview.close(window)
    }

    private func updateHighlight() {
        layer!.backgroundColor = isHovered ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : nil
        closeButton.isHidden = !isHovered || !(previewed?.canBeClosed() ?? false)
    }
}

/// Keeps an auto-hiding Dock on screen while the Dock preview panel is open. Without it the Dock slides away
/// as soon as the pointer leaves it for the panel, taking the icon the panel points at with it.
///
/// macOS has no "stay up" request for the Dock, so this turns auto-hide off and back on, as the System
/// Settings switch does. That setting persists, so the hold is recorded in our own defaults first: if the app
/// quits or crashes mid-hold, the next launch (`restoreAfterCrash`) turns auto-hide back on.
/// Main thread only.
enum DockAutohideHold {
    private static let pendingKey = "dockAutohideHeld"
    private(set) static var isHolding = false

    static func begin() {
        guard !isHolding, CoreDockGetAutoHideEnabled() else { return }
        isHolding = true
        UserDefaults.standard.set(true, forKey: pendingKey)
        CoreDockSetAutoHideEnabled(false)
        Logger.debug { "Dock auto-hide held off" }
    }

    static func end() {
        guard isHolding else { return }
        isHolding = false
        CoreDockSetAutoHideEnabled(true)
        UserDefaults.standard.removeObject(forKey: pendingKey)
        Logger.debug { "Dock auto-hide restored" }
    }

    static func restoreAfterCrash() {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        CoreDockSetAutoHideEnabled(true)
        Logger.info { "Dock auto-hide restored after an interrupted Dock preview" }
    }
}
