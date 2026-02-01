## Language
- All of comments in code base, commit message, PR content and title should be written in English.
  - If you find any Korean text, please translate it to English.
- **UI Language**: All user-facing text in the app MUST be in English.

## Coding Rules

### UI Styling Rules
- **No colors for text emphasis**: Do NOT use `NSColor` attributes like `.foregroundColor` for menu items or labels.
- **DO NOT USE SPACES TO ALIGN TEXT**: Don't use spaces like "   Words:" to align the spacing.
- **Use instead**:
  - **Bold**: `NSFont.boldSystemFont(ofSize:)` for important text
  - **Underline**: `.underlineStyle: NSUnderlineStyle.single.rawValue` for critical warnings
  - **SF Symbols**: Use `NSImage(systemSymbolName:accessibilityDescription:)` for menu item icons
  - **Emphasis**: Use system colors like secondaryLabelColor and etc.
  - **Offset**: Use offset for aligning text with other items and lines. Use the below constants.
- **Do NOT use**:
  - **Emoji**: Never use emoji for menu item icons. Always use SF Symbols instead.
  - **RGB color**: Use only pre-defined colors by system (systemGreen, systemOrange, and etc) to consider dark/light mode compatiblity.
- **Exception**:
  - While you can't use color for text, progress bars and status indicators can use system color.
  - You can use color for text which is right-aligned text only.
- Others
  - **Never use random spaces for separating label**
    - BEST:
      - Left: "OpenRouter"
      - Right: "$37.42" - Additional Custom View Label on the right with right-aligned text (by offset calculating)
    - OK: "OpenRouter: $37.42"
    - OK: "OpenRouter ($37.42)"
    - NO: "OpenRouter    $37.42" (stupid random spaces)
  - **USD**
    - Use only two decimals when expressing dollars. (e.g. `$00.00`) 

### Explicit 'used' or 'left'
- To avoid confusing of used % or left %, explicit if it's used or left on every labels.

### Menu Item Layout Constants (MUST follow strictly)
All custom menu item views MUST use these exact pixel values for consistency:
```swift
// Standard dimensions
let menuWidth: CGFloat = 300
let itemHeight: CGFloat = 22
let fontSize: CGFloat = 13

// Horizontal spacing
let leadingOffset: CGFloat = 14      // Left margin for text (no icon)
let leadingWithIcon: CGFloat = 36    // Left margin when icon present
let trailingMargin: CGFloat = 14     // Right margin

// Vertical spacing  
let textYOffset: CGFloat = 3         // Y position for single-line text
let iconYOffset: CGFloat = 3         // Y position for icons

// Icon dimensions
let iconSize: CGFloat = 16           // Standard SF Symbol size
let statusDotSize: CGFloat = 8       // Status indicator dot (circle.fill)

// Right-aligned elements position
let rightElementX: CGFloat = menuWidth - trailingMargin - iconSize  // = 270
```
- **NEVER** hardcode different pixel values in custom views
- **ALWAYS** reuse `createDisabledLabelView()` when possible instead of creating custom NSView
- When creating custom views, reference these constants to ensure alignment matches standard menu items
- **MUST** update this section if you need to define new custom spacing, margin, dimensions rules.

### Instruction of each task
- In all changes, always write debugging log for actually printing before you confirming the feature is fully functional.
- After each change, follow:
  - Clear cache and compile the binary
  - Kill the existing process, and run the new app.
  - Confirm if it works through **logs**.

## Release Policy
- **Workflow**: STRICTLY follow `docs/RELEASE_WORKFLOW.md` for versioning, building, signing, and notarizing.
- **Signing**: All DMGs distributed via GitHub Releases **MUST** be signed with Developer ID and **NOTARIZED** to pass macOS Gatekeeper.
- **Documentation**: Update `README.md` and screenshots if UI changes significantly before release.

## Tips
### How to get quota usage?
- in `@/scripts/` directory, you can see all of the scripts for every providers to get quota usage.

## Architecture Patterns

### SwiftUI Shell with AppKit Core
The app uses a hybrid architecture:
- **Entry Point**: `App/ModernApp.swift` with `@main` attribute and `MenuBarExtra`
- **Menu System**: NSMenu-based via `StatusBarController` for full native menu features
- **Bridge Pattern**: `MenuBarExtraAccess` library connects SwiftUI `MenuBarExtra` to `NSStatusItem`
```swift
// ModernApp.swift bridges SwiftUI MenuBarExtra to NSMenu
MenuBarExtra { ... }
  .menuBarExtraAccess(isPresented: $isMenuPresented) { statusItem in
    controller.attachTo(statusItem)  // Attach NSMenu to status item
  }
```

### Actor-Based Provider Architecture
All providers use Swift actors for thread-safe state management:
```swift
actor ProviderActor {
    private var cache: CachedData?
    private var isLoading = false
    
    func fetchData() async throws -> ProviderUsage {
        guard !isLoading else { return cachedData }
        isLoading = true
        defer { isLoading = false }
        // fetch logic...
    }
}
```
- **Benefits**: Eliminates data races, no manual locking needed
- **Pattern**: Use `@MainActor` for UI updates, actors for data fetching
- **Conversion**: Replace `class` with `actor`, remove `DispatchQueue.main.async`

### MenuDesignToken Usage
All menu item layouts MUST use `MenuDesignToken` constants from `Menu/MenuDesignToken.swift`:
```swift
// Use tokens instead of magic numbers
textField.frame.origin.x = MenuDesignToken.leadingOffset  // NOT: 14
progressBar.frame.size.width = MenuDesignToken.progressBarWidth  // NOT: 100
```
- **Typography**: `MenuDesignToken.primaryFont`, `MenuDesignToken.secondaryFont`
- **Spacing**: `MenuDesignToken.leadingOffset`, `MenuDesignToken.trailingMargin`
- **Dimensions**: `MenuDesignToken.menuWidth`, `MenuDesignToken.itemHeight`

### MenuBuilder Pattern
Use `@MenuBuilder` for declarative menu construction:
```swift
@MenuBuilder
func buildProviderSubmenu() -> [NSMenuItem] {
    MenuItem("Refresh") { refresh() }
    Separator()
    ForEach(providers) { provider in
        MenuItem(provider.name) { ... }
    }
}
```

<!-- opencode:reflection:start -->
### Error Handling & API Fallbacks
- **API Response Type Flexibility**: External APIs may return different types than expected
  - Numeric Fields Can Be Strings: Fields like `balance` may come as String instead of Double/Int
  - Optional Fields May Vary: Some providers return fields that others don't (e.g., `reset_at`, `limit_window_seconds`)
  - Pattern: Add computed properties for type conversion (e.g., `balanceAsDouble` converts String to Double)
  - Example Fix: Codex `balance` returned as String, added `balanceAsDouble` computed property for conversion
- **NSNumber Type Handling**: API responses may return `NSNumber` instead of `Int` or `Double`
   - Always check for `NSNumber` type when parsing numeric values from API responses
   - Pattern: `value as? NSNumber` → `doubleValue`/`intValue`
   - Example failure: Cost showing wrong value due to missing NSNumber handling
- **Menu Bar App (LSUIElement) Special Requirements**:
  - UI Display: Must call `NSApp.activate(ignoringOtherApps: true)` before showing update dialogs
  - Target Assignment: Menu item targets must be explicitly set to `NSApp.delegate` (not `self`)
  - Window Management: Close blank Settings windows on app launch
 - **Swift Concurrency & Actor Isolation**:
   - Task Capture: Always use `[weak self]` in Task blocks to avoid retain cycles
   - MainActor: Use `@MainActor [weak self]` pattern when updating UI from async contexts
   - Pre-compute Values: Cache values like `refreshInterval.title` before closures to avoid actor isolation issues
   - NotificationCenter Pattern: Use `guard let self = self else { return }` before Task, then `[weak self]` in Task capture list
- **Usage Calculation Completeness**:
  - Total Requests: Always sum both `includedRequests` AND `billedRequests` for accurate predictions
  - Prediction Algorithms: Use `totalRequests` (not just `included`) for weighted average calculations
  - UI Display: Show total requests in daily usage breakdown, not just included
 - **DMG Packaging Cleanliness**:
   - Staging Directory: Create clean staging dir containing ONLY app bundle and Applications symlink
   - Exclude Files: Prevent `Packaging.log`, `DistributionSummary.plist`, and other Xcode artifacts from DMG
   - Pattern: `mkdir -p staging; cp -R app.app staging/; ln -s /Applications staging/`
 - **DerivedData Path Handling**:
   - Wildcard Warning: Path `~/Library/Developer/Xcode/DerivedData/CopilotMonitor-*/Build/Products/Debug/OpencodeProvidersMonitor.app` may break if multiple DerivedData directories exist
   - Solution: Use `xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR` to get exact path, or open using `open` which finds the latest build
  - **Provider Type Classification**:
   - API Structure Determines Type: Provider billing model must match API response structure
   - Quota-based Indicators: `used_percent`, `remaining`, `entitlement` fields indicate quota-based model
   - Pay-as-you-go Indicators: `credits`, `usage`, `utilization` fields indicate pay-as-you-go model
   - Example Fix: Codex initially classified as pay-as-you-go, but API returns `used_percent` → corrected to quota-based
   - Test Alignment: When fixing provider type, update corresponding tests to match new implementation
 - **Menu Bar Item Lifecycle Management**:
   - Hidden Items Keep Objects Alive: Use `isHidden = true` instead of commenting out to prevent nil reference crashes
   - Implicitly Unwrapped Optionals: `NSMenuItem!` properties require initialization even if hidden from UI
   - Example Failure: Commenting out menu items causes crashes when validation logic still references them
   - Pattern: Always initialize menu items that may be referenced elsewhere, control visibility via `isHidden`
- **Language Policy Enforcement**:
   - All Log Messages Must Be English: Including debug logs, error messages, and informational logging
   - Pattern: After code changes, review log messages for Korean text and translate to English
   - Example: "fetchUsage 시작" → "fetchUsage started", "API ID 확보 성공" → "API ID obtained successfully"
   - Reference: AGENTS.md Language section requires all code comments, logs, and messages to be in English
- **Debug Code Cleanup**:
   - Remove Development Logging Before Commits: File-based debug logging (`/tmp/*.log`) should be removed after troubleshooting
   - Debug Pattern: File I/O for debugging should use `#if DEBUG` guard or be removed entirely
   - Example: Removed 110 lines of debug logging from `fetchMultiProviderData()` and `updateMultiProviderMenu()` after multi-provider feature stabilized
   - Pattern: Production code should only use structured logging (`os.log`/`Logger`), not ad-hoc file writing
  - **Access Modifier Awareness During Refactoring**:
     - Internal Access for Cross-Module Dependencies: Properties needed by external classes may need broader access (e.g., `var` instead of `private var`)
     - Example: `predictionPeriodMenu` changed from `private var` to `var` when `createCopilotHistorySubmenu()` moved to separate builder
     - Example: `getHistoryUIState()` changed from `private func` to `func` when accessed from external menu builders
     - Pattern: When extracting code to separate files, verify access modifiers still allow required dependencies
     - **Process.waitUntilExit() Blocking Issue**:
        - Synchronous Blocking: `Process.waitUntilExit()` is a blocking call even in async contexts
        - Multi-Provider Impact: Blocking providers prevent other providers from completing fetch operations
        - Async Solution: Use `withCheckedThrowingContinuation` with `terminationHandler` and `readabilityHandler` for non-blocking process execution
        - Example: AntigravityProvider uses `runCommandAsync()` wrapper; OpenCodeZenProvider uses `withCheckedThrowingContinuation` pattern
        - Pattern: Replace `waitUntilExit()` with async closure-based APIs using Process.terminationHandler and Pipe.readabilityHandler
        - Parallel Fetching Enables: Once processes are non-blocking, all providers can fetch in parallel efficiently
  - **Menu Rebuild Strategy**:
     - Tag-Based Item Removal: Use unique tags (e.g., tag 999) for dynamically generated menu items
     - Clean Rebuild Pattern: Remove all items with specific tag, then rebuild menu section from scratch
     - Separation of Concerns: Static menu items (tag 0) vs dynamic provider items (tag 999)
     - Example: `menu.items.removeAll(where: { $0.tag == 999 })` clears old provider data before fresh rebuild
     - Pattern: Tag-based filtering ensures clean menu updates without duplicating items
   - **CI/CD Build Strategy**:
     - Export Archive Failure: `xcodebuild -exportArchive` can fail in CI environments with signing issues
     - Direct Copy Solution: Use `cp -R` to copy app bundle from archive directly instead of exportArchive for unsigned builds
     - Pattern: For unsigned builds in CI, copy from `build/*.xcarchive/Products/Applications/*.app` to export directory
     - Code Signing Style: Set `CODE_SIGN_STYLE=Manual` in CI to prevent automatic signing conflicts
     - Sparkle Signature Parsing: Use `awk -F '"' '{print $2}'` to extract signature from sign_update output
     - Example Fix: Changed from exportArchive to direct copy to resolve CI build failures
   - **App Name Consistency Across Scripts**:
      - Build Scripts Must Match: App name changes require updates to pkill commands, DerivedData paths, and workflow files
      - Example: Changed from `CopilotMonitor` to `OpencodeProvidersMonitor` required updating:
        - `pkill -x CopilotMonitor` → `pkill -x OpencodeProvidersMonitor`
        - `~/Library/Developer/Xcode/DerivedData/CopilotMonitor-*/Build/Products/Debug/CopilotMonitor.app` → `OpencodeProvidersMonitor.app`
        - `.xcarchive`, `.app` bundle names in workflow files
      - Pattern: When renaming app, search all build scripts, workflows, and documentation for old name references
   - **Provider Data Ordering**:
       - API Returns Unordered Data: Dictionary iteration order is not guaranteed in Swift
       - Menu Display Issue: Provider items appearing in different order on each refresh cycle
       - Root Cause: Looping over `[ProviderIdentifier: ProviderResult]` dictionary without explicit ordering
       - Solution: Create explicit display order array or use sorted keys when iterating
       - Example: `let providerDisplayOrder = ["open_code_zen", "gemini_cli", "claude", "open_router", "antigravity"]`
       - Pattern: Define display order independently of data source to maintain consistent UI
     - **Menu Item Reference Deadlock**:
        - Shared NSMenuItem Reference: Referencing the same NSMenuItem instance (like `predictionPeriodMenu`) from multiple submenus can cause deadlocks
        - Manifestation: Menu becomes unresponsive or hangs when clicking on submenu items
        - Root Cause: NSMenuItem is not thread-safe when shared across different menu hierarchies
        - Solution: Always create fresh NSMenu instances for dynamically generated submenus instead of reusing shared references
        - Example Failure: `predictionPeriodMenu.submenu = predictionPeriodMenu` caused deadlock in history submenu
        - Fix: Create new `let periodSubmenu = NSMenu()` and rebuild contents instead of referencing existing menu
        - Pattern: Use constructor pattern to create independent menu objects for each submenu instance
   - **Loading State Management in Parallel Async Operations**:
      - Parallel Provider Fetching: All providers should fetch in parallel to minimize total fetch time
      - Loading State Tracking: Use `Set<ProviderIdentifier>` to track providers currently fetching
      - Pre-Fetch Menu Update: Update menu before starting fetch to show "Loading..." state
      - Post-Fetch Menu Update: Remove loading state and replace with actual data after fetch completes
      - Loading Item Styling: Show "Loading..." text with disabled `isEnabled = false` state
      - Pattern: `loadingProviders.insert(identifier)` → `updateMenu()` → await fetch → `loadingProviders.remove(identifier)` → `updateMenu()`
    - **Daily History Cache Strategy**:
       - Hybrid Approach: Fetch fresh data for recent days (today/yesterday), serve older data from cache
       - Timeout Risk Reduction: Reduce external CLI/API calls significantly (e.g., 7 calls → 2 calls = 71% reduction)
       - UserDefaults Cache: Use Codable structures with JSON encoding for simple persistence
       - Cache Validation: Check date before using cached data to avoid stale information
       - Sequential Internal Loading: Each provider can load history day-by-day sequentially with caching making it acceptable
       - Pattern: Load cache → fetch recent → merge → save updated cache
     - **Multiline Text Handling in Custom Views**:
        - Long Path Truncation: Displaying long file paths or URLs in disabled label views can cause content truncation
        - Pattern: Add `multiline` parameter to custom view creation functions
        - Dynamic Height Calculation: When multiline is enabled, calculate view height based on text content size
        - Implementation: `string.boundingRect(with: size, options: .usesLineFragmentOrigin, attributes: context)`
        - Example: 'Token From:' display showing full auth file path instead of truncated version
    - **Progressive Loading Race Condition Prevention**:
       - Loading State Must Precede Cleanup: Set loading state BEFORE any cleanup or killing logic
       - Race Condition Pattern: Multiple fetch calls check state (not loading), spawn tasks, then all call `killExistingOpenCodeProcesses()` before state is set
       - Symptom: Logs show repeated "Killed existing processes" and "Starting progressive fetch" messages
       - Fix: Move loading state assignment to start of function, before any cleanup operations
       - Or: Add second state check after cleanup to ensure only one instance proceeds
       - Pattern: `isLoading = true` → `killExistingProcesses()` → proceed with fetch
   - **Custom Menu View Layout Consistency with createDisabledLabelView**:
      - Vertical Alignment Mismatch: `createDisabledLabelView` uses `centerYAnchor`, custom views using `y: 3` causes pixel misalignment
      - Text Color Mismatch: `createDisabledLabelView` uses `secondaryLabelColor`, using `disabledControlTextColor` in custom views causes color difference
      - Solution: When creating custom menu item views that should align with `createDisabledLabelView` items:
        1. Use `translatesAutoresizingMaskIntoConstraints = false` and `centerYAnchor` for vertical alignment
        2. Use `secondaryLabelColor` for text color consistency
        3. Use `indent` parameter instead of spaces for horizontal indentation
      - Pattern: Match exactly what `createDisabledLabelView` does internally
      - Example Fix: Pace row changed from `frame.y = 3` to `centerYAnchor.constraint(equalTo: view.centerYAnchor)`
    - **Text Truncation in Custom Menu Views**:
       - Fixed-Width Problem: Hard-coding text field widths causes truncation for dynamic content (file paths, URLs, long labels)
       - Solution: Use `NSTextField.sizeToFit()` to calculate exact text width before positioning elements
       - Layout Pattern: Position elements from right edge (using `rightElementX`) moving left to accommodate variable-width text
       - Pattern: Right-to-left layout prevents text overflow while maintaining alignment with fixed elements
    - **Menu Bar Icon Appearance Detection**:
       - App Appearance Mismatch: Using `NSApp.effectiveAppearance` for menu bar icon color detection causes black text in light mode
       - Root Cause: Menu bar background can differ from app background appearance
       - Solution: Use `self.effectiveAppearance` (view's own appearance) for NSStatusBarButton contexts
       - Vertical Alignment: Adjust offset from `y:3` to `y:4/5` for better visual alignment with other menu bar items
       - Pattern: Always check appearance at the view level, not the app level
    - **Cache Timezone Consistency**:
       - UTC vs Local Timezone Mismatch: Cache dates stored in UTC but calendar was using local timezone (KST)
       - Comparison Failures: `isDate(..., inSameDayAs:)` comparisons failing due to timezone mismatch
       - Consequence: Cache saved but never used during progressive loading, causing unnecessary API calls
       - Solution: Use UTC calendar for all date comparisons to match cache storage format
       - Pattern: `calendar.timeZone = TimeZone(abbreviation: "UTC") ?? TimeZone.current`
     - **ISO8601 Date Parsing Flexibility**:
        - Fractional Seconds in API: API responses may include fractional seconds (e.g., "2026-02-05T14:59:30.123456Z")
        - Parsing Failure: Basic ISO8601DateFormatter() doesn't handle fractional seconds by default
        - Solution: Try parsing with `.withFractionalSeconds` first, then fallback to without
        - Pattern: Define helper function that attempts multiple format options sequentially
        - Example: `formatterWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]`
  - **Process.readabilityHandler Concurrent Mutation**:
     - Swift Concurrency Error: Modifying local variable in readabilityHandler triggers actor isolation error
     - Pattern: Use `nonisolated(unsafe)` for `outputData` in async Process handlers
     - Safety Guarantee: Handlers are serialized by Process lifecycle, making this safe
     - Example Fix: OpenCodeZenProvider and AntigravityProvider both use this pattern
     - Implementation: `nonisolated(unsafe) var outputData = Data()`
  - **Prediction Range Boundary Safety**:
     - Negative Range Assertion: Counting remaining days can result in `remainingDays <= 0` on month-end
     - Crash Location: `1...remainingDays` range assertion fails when negative or zero
     - Solution: Add guard clause before range iteration to return early
     - Pattern: `guard remainingDays > 0 else { return (0, 0) }`
     - Context: Usage prediction on last day of month causes EXC_BREAKPOINT crash within 1-3 seconds of app launch
   - **TimeZone Force Unwrap Safety**:
      - Force Unwrap Risk: `TimeZone(identifier: "UTC")!` can crash if identifier is invalid
      - Safe Initialization: Use optional binding with fallback to system timezone
      - Pattern: `if let utc = TimeZone(identifier: "UTC") { cal.timeZone = utc } else { cal.timeZone = TimeZone.current }`
      - Application: All calendar instances that require UTC timezone for date calculations
      - Example Fix: UsagePredictor, UsageHistory, StatusBarController updated with safe initialization
   - **Menu Structure Validation Logging**:
      - Validation Helper: Add `logMenuStructure()` function to verify menu completeness after setup
      - Metrics to Log: Total items, separator count, action items count, submenu count
      - Debug Output Format: `📋 [Menu] Items: N (sep:X, actions:Y, submenus:Z)`
      - Verification Method: Use `log stream --predicate 'subsystem == "com.opencodeproviders"'` or check `/tmp/provider_debug.log`
      - Pattern: Call `logMenuStructure()` at end of `setupMenu()` for initial validation and after updates
   - **Keyboard Shortcut Logging for Verification**:
      - Handler Logging: Add log statements to all keyboard shortcut action methods
      - Log Format: `⌨️ [Keyboard] ⌘<key> <action> triggered`
      - Benefits: Verify shortcuts work via logs without manual UI testing, catch unassigned shortcuts
      - Example Patterns: `⌨️ [Keyboard] ⌘R refresh triggered`, `⌨️ [Keyboard] ⌘Q quit triggered`
      - Search Method: Use `cat /tmp/provider_debug.log | grep "⌨️"` to find all keyboard events
   - **Loading Menu Item Style Consistency**:
      - Standard NSMenuItem: Use `NSMenuItem(title:action:keyEquivalent:)` instead of `createDisabledLabelView` for loading states
      - Disabled State: Set `isEnabled = false` to visually indicate loading without custom views
      - Alignment Benefits: Standard NSMenuItem aligns perfectly with regular menu items, avoiding custom view pixel mismatches
      - Pattern: `let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: ""); item.isEnabled = false`
      - Example Fix: Pay-as-you-go, Quota Status, and Gemini CLI loading items unified to use standard NSMenuItem

             <!-- opencode:reflection:end -->
