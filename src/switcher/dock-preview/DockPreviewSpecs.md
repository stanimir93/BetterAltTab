# Dock previews

Hovering an app's icon in the Dock shows a panel with one thumbnail per window of that app, like the
Windows taskbar. Setting: "Window previews on Dock hover" (`dockPreviews`, on by default).

## Behavior

- The panel appears 0.3s after the pointer settles on an app icon. While it is open, moving to another
  app's icon swaps the contents at once.
- It lists the windows the switcher knows for that app, minimized ones included, without inactive tabs or
  phantom windows. Apps with no window show nothing (the Dock's own label remains).
- Thumbnails are refreshed when the panel opens. A window with no capture yet (no Screen Recording
  permission, or minimized before it was ever captured) shows its app icon.
- Clicking a thumbnail focuses that window and hides the panel. Hovering a thumbnail shows an × that closes
  the window; middle-click closes it too.
- The panel hides 0.25s after the pointer leaves both the panel and its icon, at once on any click or key
  press elsewhere, and whenever the switcher is summoned.
- It opens above a bottom Dock and beside a left or right Dock, centered on the icon and kept on screen.
  When the windows don't fit along the screen, every thumbnail shrinks by the same factor.
- With Dock auto-hide on, the Dock stays on screen while the panel is open, so the pointer can travel from
  the icon to the panel. The panel turns auto-hide off when it opens and back on when it closes, as the
  System Settings switch would. If the app quits or crashes while the panel is open, the next launch turns
  auto-hide back on (the `dockAutohideHeld` default marks a hold in progress).
- An auto-hiding Dock reports the hovered icon while it is still sliding in, so the icon's frame is read
  again when the panel opens, and once more after the slide-in (0.35s) if the hold had to stop the Dock.

## How hover is detected

The Dock's AXList posts `AXSelectedChildrenChanged` as the hovered icon changes and when the pointer leaves
the Dock. `AXSelectedChildren` is the hovered icon: an `AXApplicationDockItem` with `AXURL` (the app
bundle), `AXPosition` and `AXSize`. The icon's frame tells which edge the Dock is on.

## Tests

`DockPreviewLayoutTests` covers the geometry:

- **testEdgeIsTheScreenSideTheIconHugs**: bottom, left and right Docks are told apart from the icon frame.
- **testThumbnailsKeepTheWindowShapeWithinClamps**: thumbnails keep each window's shape, within limits.
- **testTooManyWindowsShrinkToFitTheScreen**: a long row shrinks to the screen.
- **testBottomDockPanelSitsAboveTheIconAndStaysOnScreen** and **testSideDockPanelOpensAwayFromTheEdge**:
  placement.
- **testBridgeCoversTheGapBetweenIconAndPanel**: the pointer can cross from the icon to the panel without
  the panel hiding.
- **testFitCentersAndKeepsAspect**: thumbnails are aspect-fit into their slot.
