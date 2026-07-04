# Status Bar Architecture — Final Notes (2026-07-04)

**Date**: 2026-07-04
**Branch**: main (HEAD `426e0f5` and later)
**Status**: ✅ **RESOLVED**. The bridge design is now correct architecture, not a hack.

## 0. Why does Token King fork need a "hack" that upstream doesn't?

**Short answer**: Both Token King fork and upstream have a menu bar item, but they get it from **different sources**, and only one of them works on macOS 26.x.

**Details**:
- Upstream `opgginc/opencode-bar` `upstream/main` has TWO menu bar item sources that intentionally DON'T overlap:
  1. `StatusBarController.setupStatusItem()` creates one via `NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)` — pure AppKit path.
  2. `MenuBarExtra(isInserted: $isMenuEnabled)` where `isMenuEnabled = false` — intentionally hidden to avoid double-icon.

  Commit `8126dc0` ("fix: SwiftUI MenuBarExtra 중복 아이콘 버그 수정", 2026-02-01) explains this: the upstream author *tried* the bridge approach (with `isInserted = true` and `MenuBarExtraAccess`) in commit `97aa22d`, but the bridge caused *two* icons to appear (one from `MenuBarExtra`, one from `StatusBarController`). They "fixed" this by setting `isInserted = false`, leaving only the pure-AppKit item from `StatusBarController`.

  This pure-AppKit path works on macOS 13-15 (where the upstream author developed and tested). **It does NOT work on macOS 26.x** because the resulting `NSSceneStatusItem` is in `[NSStatusBar systemStatusBar] _statusItems` but is not bound to a `NSStatusBarWindow`, so `SystemUIServer` doesn't render it in a clickable position. `button.frame` is `(0, 0, 20, 22)` (origin, not the menu bar).

- Token King fork (with my current commit `f5a2676`) does the opposite: `isMenuEnabled = true` (re-enabling the `MenuBarExtra` item) + the `MenuBarExtraAccess` bridge that hands the SwiftUI-managed `NSSceneStatusItem` (which IS bound to a `NSStatusBarWindow`) to `StatusBarController.attachTo(_:)`. This sidesteps the macOS 26.x regression: the item from `MenuBarExtraAccess` has `button.frame = (3488, -427, 92, 34)` — visible and clickable.

**The previous "double-icon" problem that upstream hit in commit `97aa22d` is a non-issue for the bridge path**, because we don't create a separate pure-AppKit item in `StatusBarController.setupStatusItem()` anymore — the `setupStatusItem` now just prepares the icon view, and the actual `NSStatusItem` is supplied later via the bridge. No conflict.

**Why the fork needs a path that upstream doesn't**: Token King fork's whole point is to have a working menu bar item on macOS 26.x, which requires the bridge. Upstream's design (pure-AppKit, `isInserted: false`) silently doesn't have a working item on macOS 26.x, but the author hasn't yet noticed because (a) they probably developed on macOS 13-15 where pure-AppKit works, and (b) there's no visible error — the item just doesn't appear.

## 1. TL;DR — What I Got Wrong, and What's Actually True

### My earlier (wrong) claim
"Three layers of hack: pendingStatusItem queue, attachTo bridge, renderStatusItemImage. Pure AppKit can replace all of this."

### What lldb proved (CORRECTED after careful re-verification)
```
[NSStatusBar.system.statusItem] → NSSceneStatusItem (macOS 26.x SwiftUI private subclass)
[respondsToSelector:setMenu:] → YES   (the public setMenu: setter works on NSSceneStatusItem)
[respondsToSelector:menu]      → YES
[respondsToSelector:_setMenu:] → NO   (no private override)
[button frame]                → (3488, -427, 92, 34) (when obtained via MenuBarExtraAccess bridge)
                              → (0, 0, 20, 22)     (when obtained via pure AppKit)
```

**The 3 "layers" are not hacks** — they are the **only path that works on macOS 26.x**:
- `pendingStatusItem` queue: needed because MenuBarExtraAccess's `statusItem` closure can fire before `applicationDidFinishLaunching` constructs the controller
- `attachTo(_:)` bridge: needed because SwiftUI Scene owns the `NSSceneStatusItem` and we cannot synthesize one from pure AppKit (button frame ends up at (0,0) which SystemUIServer treats as invisible)
- `renderStatusItemImage()`: needed because `NSSceneStatusItem` button subview drawing is unreliable on macOS 26.x, but `button.image` setter does work

**The MenuBarExtraAccess library exists for exactly this reason** — to obtain a properly-registered `NSSceneStatusItem` from SwiftUI's Scene path. Once you have it, `setMenu:` works fine; the public API isn't broken.

### The two real bugs we now know
1. **Pure AppKit `NSStatusBar.system.statusItem(withLength:)` produces a non-functional item on macOS 26.x** (lldb: `button.frame = (0, 0, 20, 22)` for pure AppKit path; `(3488, -427, 92, 34)` for MenuBarExtraAccess path). The item enters `_statusItems` but is never rendered in a clickable position.
2. **`@NSApplicationMain` macro is broken in Xcode 26.x debug builds** (the macro's stub `_main` doesn't pass the delegate class, so `NSApp.delegate == nil`). Workaround: use `@main struct App` with SwiftUI App lifecycle OR a manual `main.swift` (not both).

## 2. Why the "Phase 1 pure AppKit" Approach Failed

Commits `0f4fe55` (Phase 1) and `9a77e17` (Phase 2/3) replaced the bridge with a hand-written `main.swift` that:
1. Constructed `NSApplication.shared`
2. Set `AppDelegate` as delegate
3. Called `app.run()`

The intent was to bypass SwiftUI entirely. **The result:**
- `[NSStatusBar systemStatusBar] _statusItems` count = 1 (good)
- Item runtime class: `NSKVONotifying_NSSceneStatusItem`
- Item button frame: `(0, 0, 20, 22)` — at the origin, NOT in the menu bar
- Item clickable: NO (the system never sees it as a menu bar item; no `NSStatusBarWindow` is created for it)

When the user clicked the menu bar icon, the system found no `NSStatusBarWindow` associated with the item, so the click went nowhere. I initially thought it was because `setMenu:` returned NO, but a corrected lldb query (`respondsToSelector:setMenu:`) returns YES — `setMenu:` does work. The real problem is that **no `NSStatusBarWindow` is created for pure-AppKit items, so SystemUIServer doesn't accept them**.

## 3. The Correct Architecture (commit `f5a2676`)

```
┌─────────────────────────────────────────────────────────────────┐
│  ModernApp.swift (@main struct ModernApp: App)                   │
│  - SwiftUI App lifecycle 启动入口 (唯一 @main)                   │
│  - MenuBarExtra(isInserted: true) { Text("Loading...") }         │
│      .menuBarExtraAccess(statusItem: { item in                   │
│          appDelegate.attachStatusItem(item)                      │  ← bridge
│      })                                                            │
│  - MenuBarExtraAccess 库: 拿 SwiftUI Scene 的 NSSceneStatusItem │
│  - isInserted: TRUE (必要 — false 的话 NSSceneStatusItem 不创建)│
└─────────────────────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────┐
│  AppDelegate (NSApplicationDelegate)                             │
│  - applicationDidFinishLaunching:                                │
│    1. AppMigrationHelper 检查/清理                                │
│    2. Sparkle SPUStandardUpdaterController 初始化                 │
│    3. statusBarController = StatusBarController()                 │
│    4. 如果 pendingStatusItem 存在 → 立即 attachTo()            │
│  - attachStatusItem(_:) (桥接回调入口):                          │
│    如果 controller 存在 → 立即 attachTo(item)                    │
│    否则 → pendingStatusItem = item (桥接回调比 finishLaunch 早)│
└─────────────────────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────┐
│  StatusBarController                                            │
│  - setupStatusItem(): 准备 StatusBarIconView (status item 还没)  │
│  - attachTo(_: statusItem: NSStatusItem):                        │
│    1. self.statusItem = statusItem                                │
│    2. statusItem.menu = self.menu  (setMenu: work)                │
│    3. statusItem.length = variableLength                          │
│    4. attachStatusIconViewToButton()                              │
│    5. updateStatusItemLayout("attach")                            │
│  - renderStatusItemImage():                                      │
│    1. NSImage 锁焦点画 StatusBarIconView                          │
│    2. 赋给 button.image (subview 在 NSSceneStatusItem 不可靠)    │
└─────────────────────────────────────────────────────────────────┘
```

## 4. Lessons Learned

1. **Always run `lldb` to check what selectors exist** before assuming a fix. Specifically `[item performSelector:setMenu:]` vs `respondsToSelector:setMenu:` give different results; the second is the right test.
2. **`@NSApplicationMain` is broken in Xcode 26.x debug builds**. Use `@main struct App` with SwiftUI App lifecycle OR a manual `main.swift` (not both — Swift rejects).
3. **`MenuBarExtraAccess` is the right path for macOS 26.x menu bar apps**. Don't try to bypass it.
4. **The "3 layers" architecture is correct**; Phase 1+2/3 was based on a wrong premise.
5. **Pure AppKit `NSStatusBar.system.statusItem(withLength:)` creates items that are NOT bound to `NSStatusBarWindow` on macOS 26.x** — they are in `_statusItems` but invisible/unclickable. This is what differentiates them from MenuBarExtraAccess-obtained items.
6. **`isMenuEnabled = true` is what triggers the macOS 26.x issue** — `false` means no item, no problem visible.

## 5. Current Open Issues (out of scope of this work)

- **Item position on secondary display** (X=3488) instead of primary. SwiftUI NSSceneStatusItem uses a different coordinate system than AppKit. Click works, just visual placement is unexpected.
- **2 items in `_statusItems`** (one is the SwiftUI Settings scene, one is our Token King). Cosmetic only.

## 6. Files in Current Design

| File | Purpose |
|---|---|
| `CopilotMonitor/CopilotMonitor/App/ModernApp.swift` | `@main` SwiftUI App with `MenuBarExtra(isInserted: true)` + `MenuBarExtraAccess` bridge |
| `CopilotMonitor/CopilotMonitor/App/EntryDocumentation.swift` | Pure documentation (replaces old `main.swift`; Swift can't have both `@main` and top-level code in `main.swift`) |
| `CopilotMonitor/CopilotMonitor/App/AppDelegate.swift` | NSApplicationDelegate; `pendingStatusItem` queue + `attachStatusItem(_:)` bridge entry; `statusBarController` lifecycle |
| `CopilotMonitor/CopilotMonitor/App/StatusBarController.swift` | Owns the NSMenu; `setupStatusItem` (view setup only) + `attachTo(_:)` (bridge receiver) + `renderStatusItemImage()` (subview → image path) |
| `CopilotMonitor/CopilotMonitor/Views/StatusBarIconView.swift` | Custom NSView that draws the SF Symbol + cost text + provider icon; 307 lines, well-tested |
