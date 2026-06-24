# Radial launcher (second drag mode)

Hold **⌃ Control** + drag a file → a radial wheel of favorite apps appears **around the
cursor**. Flick toward a wedge, release → the file opens in that app. Normal drag (no
Control) keeps the existing notch-pill flow.

## Decisions (confirmed)
- Trigger: hold **Control** at drag start (configurable; default Control).
- Position: centered at the cursor where the hotkey-drag is detected.
- Apps: `FavoriteToolsStore.resolvedTools(for: urls)` (category-aware, ≤9).
- Launch is programmatic (`launch(tool, with: urls)`); URLs read from the drag pasteboard.

## Key mechanism
A **full-screen transparent NSPanel** that is an `NSDraggingDestination`:
- Intercepts the drop so the file never lands on the desktop/app behind.
- `draggingUpdated` → live cursor → highlight wedge.
- `performDragOperation` → launch the highlighted app (or cancel in the centre dead-zone).
- `draggingEnded` → safety cancel (e.g. Esc).

## Tasks
1. `HotkeyManager`: add `radialEnabled` (def true) + `radialModifiers` (def .control) +
   `isRadialHotkeyHeld()`.
2. `DragMonitor`: in `handleDrag`, if Control-radial held → `RadialLauncherController.begin(urls:)`
   and DO NOT set `isDraggingFile` (suppress the pill). Add a `fileURLs(on:)` reader.
3. NEW `UI/RadialLauncher.swift`: controller (singleton, ObservableObject) + `RadialWindow`
   (full-screen panel) + `RadialDropView` (NSDraggingDestination) + `RadialMenuView` (SwiftUI
   donut, wedge highlight, icons, centre label) + `RingShape`/annular-sector geometry.
4. `SettingsView`: General → "Radial Launcher" toggle + modifier note.
5. Build green.

## Geometry
View space (y-down). Center = invocation cursor (screen→view converted). Tool i at
θ_i = −90° + i·360/N, icon at R_mid. Cursor: r<innerR ⇒ no selection (cancel); else
index = round((φ − θ_0)/(360/N)) mod N. Highlight = annular sector [θ_i±half], inner→outer.
