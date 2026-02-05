## Important Restriction
- All of comments in code base, commit message, PR content and title should be written in English.
  - If you find any Korean text, please translate it to English.
- **UI Language**
  - All user-facing text in the app MUST be in English.

### Obey design decisions that specifically decided before by me
- All the decision is speicifed in `@AGENTS-design-decisions.md` file.

## Coding Rules

### Branding Guides
- Official Brand: `OpenCode Bar`
  - Don't use mis-capitalized or malformed forms like `Opencode Bar` or versions without the space (e.g. `OpenCodeBar`).
- File Name:
  - `OpenCode Bar` if it allows whitespace.
  - `OpenCode-Bar` if it allows dash.
  - `opencode-bar` (all lowercase) if the environment prefers lowercase file names.
  - `opencodebar` (all lowercase, no separators) if it doesn't allow whitespace or dashes.
- Bundle ID: `com.copilotmonitor.CopilotMonitor`

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
All custom menu item views MUST use `MenuDesignToken` from `Helpers/MenuDesignToken.swift`:
```swift
// Usage examples
let width = MenuDesignToken.Dimension.menuWidth      // 300
let height = MenuDesignToken.Dimension.itemHeight    // 22
let fontSize = MenuDesignToken.Dimension.fontSize    // 13
let iconSize = MenuDesignToken.Dimension.iconSize    // 16

let leading = MenuDesignToken.Spacing.leadingOffset      // 14
let leadingIcon = MenuDesignToken.Spacing.leadingWithIcon // 36
let trailing = MenuDesignToken.Spacing.trailingMargin    // 14

let font = MenuDesignToken.Typography.defaultFont
let mono = MenuDesignToken.Typography.monospacedFont
let bold = MenuDesignToken.Typography.boldFont

let rightX = MenuDesignToken.rightElementX  // 270 (computed)
```
- **NEVER** hardcode pixel values - always use `MenuDesignToken`
- **ALWAYS** reuse `createDisabledLabelView()` when possible instead of creating custom NSView
- When adding new constants, add them to `MenuDesignToken.swift` first, then update this section

### Pre-Development Setup (MUST run before any work)
Before starting any development work, run:
```bash
make setup
```
This sets up git hooks for automated pre-commit checks:
- **SwiftLint**: Validates Swift code style
- **action-validator**: Validates GitHub Actions workflow YAML files

### Build & Run Commands
Use the VSCode task "🐛 Debug: Kill + Build + Run" for development.
- Automatically detects DerivedData path via `xcodebuild -showBuildSettings`
- Works with multiple worktrees (each has its own DerivedData directory)

```bash
# Watch logs
log stream --predicate 'subsystem == "com.opencodeproviders"' --level debug
# or check file: cat /tmp/provider_debug.log
```

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

### CI Universal Binary
- Release workflows must build universal macOS binaries (`arm64` + `x86_64`) and verify with `lipo -archs` for both the main app and the embedded CLI before notarization.

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
- **Dynamic Binary Search for External Dependencies**: Don't hardcode paths for external executables
   - Multiple Strategy Approach: Try 'which' command, login shell PATH, then fallback paths
   - Installation Variations: Users may install tools via Homebrew, pip, or custom locations
   - Example Failure: Users with Homebrew installation couldn't use app (hardcoded ~/.opencode/bin/opencode)
   - Fix: Implement `findBinaryViaWhich()`, `findBinaryViaLoginShell()`, and hardcoded fallback array
   - Pattern: Lazy initialization with `private lazy var opencodePath` ensures search runs only once
- **Auth File Discovery Fallback**: Configuration files may exist in multiple locations
   - Multiple Path Support: Check XDG_DATA_HOME, ~/.local/share, and ~/Library/Application Support
   - Priority Order: Respect environment variables, then XDG defaults, then platform conventions
   - Example Failure: Auth file not found error (#15) when using different OpenCode configurations
   - Fix: Implement `getAuthFilePaths()` with sequential fallback attempts
   - Pattern: Track `lastFoundAuthPath` for debug visibility and reuse
- **API Response Type Flexibility**: External APIs may return different types than expected
  - Numeric Fields Can Be Strings: Fields like `balance` may come as String instead of Double/Int
  - Optional Fields May Vary: Some providers return fields that others don't (e.g., `reset_at`, `limit_window_seconds`)
   - Pattern: Add computed properties for type conversion (e.g., `balanceAsDouble` converts String to Double)
   - Example Fix: Codex `balance` returned as String, added `balanceAsDouble` computed property for conversion
- **Cache Fallback on External Command Failures**: When external CLI/API commands fail, use cached data
   - Graceful Degradation: Wrap external command calls in try-catch to prevent app crashes
   - Fallback Calculation: Calculate metrics from cached data when external command fails
   - Example: OpenCode Zen `stats --days` command failure falls back to cache for totalCost display
   - Pattern: Add `calculateTotalCostFromCache()` method, wrap stats load in try-catch
   - UI Feedback: Show `[stats: cached]` label to indicate fallback mode
   - Benefit: App remains functional even when external tools are temporarily unavailable
- **Appcast XML Generation in Workflows**: Heredoc can cause XML parsing errors
   - Problem: Using heredoc to write appcast.xml in GitHub Actions workflows causes parsing failures
   - Root Cause: Heredoc indentation or whitespace issues corrupt XML structure
   - Fix: Use `printf` command instead of heredoc for XML generation
   - Example: Changed from `cat << 'EOF' > appcast.xml` to `printf '%s\n' '...' > appcast.xml`
   - Pattern: Use printf for structured data files (XML, JSON) in CI/CD workflows
- **NSNumber Type Handling**: API responses may return `NSNumber` instead of `Int` or `Double`
   - Always check for `NSNumber` type when parsing numeric values from API responses
   - Pattern: `value as? NSNumber` → `doubleValue`/`intValue`
   - Example failure: Cost showing wrong value due to missing NSNumber handling
- **Menu Bar App (LSUIElement) Special Requirements**:
  - UI Display: Must call `NSApp.activate(ignoringOtherApps: true)` before showing update dialogs
   - Target Assignment: Menu item targets must be explicitly set to `NSApp.delegate` (not `self`)
   - Window Management: Close blank Settings windows on app launch
- **Sparkle Update App Bundle Migration**: When app name changes, old bundles need migration
   - Problem: Sparkle replaces bundle contents but keeps folder name, causing "damaged" errors
   - Security: Use native FileManager/NSWorkspace APIs instead of bash scripts for migration
   - Validation: Check bundle ID before deletion to prevent accidental deletion of unrelated apps
   - Version Protection: Compare versions before deleting, launch existing app if same/newer
   - Fix: Add `AppMigrationHelper` to automatically migrate (e.g., CopilotMonitor.app → OpenCode Bar.app)
   - Pattern: Implement migration on app launch, use CFBundleExecutable for correct resolution
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
       - Example: `let providerDisplayOrder = ["opencode_zen", "gemini_cli", "claude", "openrouter", "antigravity"]`
       - Pattern: Define display order independently of data source to maintain consistent UI
   - **Z.AI API Date Format**:
       - Parameter Validation Error: Z.AI API returns 500 error when using milliseconds timestamp for `startTime`/`endTime`
       - Requirement: API explicitly requires `yyyy-MM-dd HH:mm:ss` format string
       - Fix: Use `DateFormatter` with `UTC` timezone instead of `Int64` timestamps
       - Pattern: Always verify API time format requirements (timestamp vs ISO8601 vs custom string)
       - Example: `dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"`
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
   - **Error Status Display Instead of Loading**: Show meaningful status when auth is missing or errors occur
      - Authentication Errors: Use `isAuthenticationError()` function to detect missing credentials
      - Status Labels: Show "No Credentials" for auth errors, "Error" for general errors
      - Infinite Loading Prevention: Remove failed providers from `loadingProviders` set to prevent repeated attempts
      - Example Fix: Pay-as-you-go, Quota Status, and Gemini CLI sections show proper error states
      - Pattern: Try-catch wrapper → check error type → update UI with status → remove from loading set
   - **SwiftUI MenuBarExtra + AppKit NSStatusItem Duplication**:
      - Problem: Using both SwiftUI `MenuBarExtra` AND creating `NSStatusItem` directly causes TWO menu bar icons
      - Root Cause: Each approach independently creates a status bar item
      - Solution: Use ONLY ONE approach - either SwiftUI MenuBarExtra with bridge, or pure AppKit NSStatusItem
      - Current Pattern: SwiftUI MenuBarExtra with `isInserted: $isMenuEnabled` set to `false`, AppKit NSStatusItem handles everything
      - Anti-Pattern: Creating `NSStatusBar.system.statusItem()` while also using `MenuBarExtra { }`
      - Example Fix: Set `@State private var isMenuEnabled = false` and use `MenuBarExtra(isInserted: $isMenuEnabled)`
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
    - **SwiftUI MenuBarExtra + AppKit NSStatusItem Duplication**:
       - Problem: Using both SwiftUI `MenuBarExtra` AND creating `NSStatusItem` directly causes TWO menu bar icons
       - Root Cause: Each approach independently creates a status bar item
       - Solution: Use ONLY ONE approach - either SwiftUI MenuBarExtra with bridge, or pure AppKit NSStatusItem
       - Current Pattern: SwiftUI MenuBarExtra with `isInserted: $isMenuEnabled` set to `false`, AppKit NSStatusItem handles everything
       - Anti-Pattern: Creating `NSStatusBar.system.statusItem()` while also using `MenuBarExtra { }`
       - Example Fix: Set `@State private var isMenuEnabled = false` and use `MenuBarExtra(isInserted: $isMenuEnabled)`
     - **GitHub Actions YAML Indentation Syntax Errors**:
        - Strict Indentation Rules: YAML is whitespace-sensitive and incorrect indentation causes workflow failures
        - Common Mistake: Excessive indentation makes steps appear nested incorrectly (e.g., 14 spaces instead of 6)
        - Validation: GitHub Actions checks YAML syntax before execution and reports indentation errors
        - Pattern: Each job step should be at consistent indentation level (typically 6 spaces for top-level job steps)
        - Example Fix: Fixed `- name: Create Release` step indentation from 14 spaces to 6 spaces
        - Affected Files: `build-release.yml`, `manual-release.yml` when adding release steps
        - Prevention: Use YAML linters or validate syntax with `yamllint` before committing
   - **Menu Update Debouncing**:
        - Redundant Rebuild Issue: Multiple `updateMultiProviderMenu` calls occurring in quick succession
        - Symptoms: Logs showing repeated menu structure outputs with identical data
        - Root Cause: No debouncing mechanism to prevent concurrent or rapid successive update requests
        - Solution: Implement debounce timer or check if update is already in progress before triggering new rebuild
        - Pattern: `updatePending = false` → schedule update → check `!updatePending` before proceeding → set `updatePending = true`
   - **Cache Effectiveness for Progressive Loading**:
        - Initial Fetch Pattern: OpenCode Zen fetches 30 days progressively (~3 minutes total: 30 days × 4-6 seconds each)
        - Cache Threshold: 1-hour cache window appropriate for usage data that changes infrequently
        - Cache Success: Subsequent fetches show "(cached)" for all days, instant response
         - Pattern: Hybrid approach (fetch recent + cache older) reduces API calls by 71%+
         - Optimization: Ensure cache validation uses UTC calendar to match cache storage format
   - **GitHub Actions Workflow Input Handling**:
      - Event Type Dependencies: Workflow inputs may not be available on all event types
      - Example Failure: `inputs.version` undefined on push/PR events, causing workflow failure
      - Solution: Use environment variable gating with `event_name` checks before accessing inputs
      - Pattern: Check `github.event_name` to determine if dispatch event with manual inputs
      - Prevention: Use conditional logic or provide default values for non-dispatch events
   - **CLI Binary Bundle Embedding**:
      - Build Phase Requirement: CLI binaries must be embedded in app bundle via PBXCopyFilesBuildPhase, not just built alongside app
      - Error Pattern: "CLI binary not found at expected path in app bundle" when menu item tries to locate binary
      - Xcode Configuration: Set dstSubfolderSpec = 1 (Wrapper) and subpath to Contents/MacOS
      - Target Dependencies: Add PBXTargetDependency to ensure CLI builds before main app
      - Code Signing: Set CodeSignOnCopy attribute on PBXBuildFile entry for CLI binary
      - Verification: Binary appears at CopilotMonitor.app/Contents/MacOS/opencodebar-cli with executable permissions
      - Pattern: Always test "Install CLI" menu item after build to verify binary accessibility
   - **Progressive Loading Performance Optimization**:
      - Problem: Each progressive loading step triggers full menu rebuild, causing UI flicker and performance degradation
      - Symptom: Logs show repeated "updateMultiProviderMenu: started" with "Loading day X/30..." messages
      - Root Cause: OpenCode Zen fetches 30 days sequentially, calling full menu update after each day
      - Solution: Implement partial menu updates during progressive loading
        - Update only the specific submenu item (e.g., "Loading day X/30...")
        - Avoid rebuilding entire menu structure for incremental updates
        - Use menu item references to update in-place instead of full rebuild
      - Performance Impact: 30 days × full rebuild = ~30x slower than necessary
      - Pattern: `updateLoadingProgress(dayIndex)` → update single loading item → `updateMenu()` only on completion
   - **Debug Log Frequency Control**:
       - Excessive Logging: `logMenuStructure()` called on every menu update produces massive log output
       - Symptom: Logs show repeated identical menu structures hundreds of times during progressive loading
       - Solution: Use debug guards or log level controls for verbose structure logging
       - Pattern: `#if DEBUG logMenuStructure()` or move to trace-level logging instead of debug
       - Recommendation: Disable structure logging after initial validation, enable only when debugging menu issues
   - **Pace Row Overlap Prevention**:
       - Overlap Risk: Left and right labels can collide when the right-side status text grows long
       - Solution: Use Auto Layout with compression resistance priorities and right-aligned constraints
       - Pattern: Left label `.defaultLow`, right label `.required`, and `lessThanOrEqualTo` spacing
   - **Used-Up Pace Label Suppression**:
       - Clarity Issue: Showing "Pace: Used Up" alongside wait text is redundant and noisy
       - Solution: Hide the pace label entirely when usage is exhausted
       - Pattern: `leftTextField.isHidden = true` when `isExhausted` is true
   - **Wait Time Formatting Rules**:
       - Consistency Need: Different wait durations should display with predictable granularity
       - Rule: Show `Xd Yh` for 1d+, `Xh` for 1h+, and `Xm` for under 1h
       - Pattern: Centralize in a single formatter function for all used-up messages
   - **Silent Error Handling for Non-Critical Operations**:
        - Empty Catch Blocks: Use `catch {}` for operations where failure doesn't impact core functionality
        - Appropriate Use Cases: Optional config file reading, CLI binary detection, environment discovery
        - Safety Consideration: Only use when operation is truly non-critical and has fallback behavior
        - Example: TokenManager uses silent catches for finding opencode binary - app still works if not found
        - Pattern: `try? readOptionalConfig()` or `} catch { // Ignore non-critical failures }`
    - **AppleScript Path Escaping for Security**:
       - Command Injection Risk: Direct string interpolation in AppleScript allows path manipulation attacks
       - Solution: Use AppleScript's `quoted form of` to safely escape paths with spaces and special characters
       - Security Impact: Prevents privilege escalation via crafted app bundle paths
       - Implementation Pattern:
         ```applescript
         set cliPath to "\(cliPath)"
         do shell script "mkdir -p /usr/local/bin && cp " & quoted form of cliPath & " /usr/local/bin/opencodebar && chmod +x /usr/local/bin/opencodebar"
         ```
       - Example Fix: CLI installation AppleScript now safely handles paths containing spaces or special characters
    - **CLI Exit Code Consistency**:
       - Empty Results Handling: Exit with error code 1 when no provider data is available (not 0)
       - Error Output: Write error messages to stderr instead of stdout for proper scripting error detection
       - Pattern: Check `guard !results.isEmpty`, write to `FileHandle.standardError`, exit with `CLIExitCode.generalError.rawValue`
       - Automation Benefit: Scripts can detect failures via exit code 1 instead of success code 0
    - **Timeout-Based Error Handling with withThrowingTaskGroup**:
       - Prevent API Hangs: Use `withThrowingTaskGroup` with timeout task to prevent indefinite waits
       - Configurable Timeout: Default 30s timeout allows slow APIs to complete but prevents deadlocks
       - Cancellation: First success cancels all other tasks (timeout or fetch)
       - Pattern: Add timeout task with `Task.sleep(nanoseconds:)` that throws after configured duration
       - Example: ProviderManager.swift fetchWithTimeout() prevents unresponsive providers from blocking entire fetch cycle
    - **Retry Pattern with Exponential Backoff**:
       - Transient Failure Recovery: Retry operations that may fail temporarily with increasing delays
       - Max Retries: Typically 3 attempts before giving up
       - Backoff Delay: 500ms between retries is common pattern in this codebase
       - Pattern: `for attempt in 1...maxRetries { try { return op } catch { await Task.sleep(backoff) } }`
       - Example: OpenCodeZenProvider retries stats command up to 3 times with 500ms delays
    - **Graceful Degradation for Multi-Account Providers**:
       - Partial Success Handling: Continue processing when some accounts fail but others succeed
       - Multi-Provider Architecture: Gemini CLI supports multiple accounts, treat as partial success if any succeed
       - Failure Condition: Only throw error if ALL accounts fail, not just some
       - Pattern: Loop through accounts with try-catch, collect successes, throw only if results array empty
       - Example: GeminiCLIProvider shows quota for working accounts even if one account's auth fails
    - **Specific Error Type Catching**:
       - Precise Error Classification: Catch specific error types for better error messages and handling
       - Distinguish Failure Modes: Separate decoding errors from network errors vs authentication failures
       - Pattern: `catch let error as DecodingError { throw ProviderError.decodingError(...) } catch { ... }`
       - Example: ClaudeProvider catches DecodingError separately to provide more helpful parsing error messages
    - **Debug Log Emoji Prefix Convention**:
       - Standardized Status Indicators: Use consistent emoji for log message types across all components
       - Status Emojis: 🔵 (blue) for start, 🟡 (yellow) for in-progress, 🟢 (green) for success, 🔴 (red) for failure
       - Action Emojis: ⌨️ for keyboard shortcuts, 📋 for menu structure, 🔄 for refresh operations
       - Result Emojis: ✅ for success results, ❌ for errors, ⚠️ for warnings
       - Pattern: `[🔵 ComponentName] Starting operation`, `[🟢 ComponentName] Operation completed: 42 items`
       - Benefit: Easy visual scanning of logs to track execution flow and identify issues quickly
    - **Consistent Debug Log Function Pattern**:
       - Reusable Helper: Each component has `debugLog()` function for centralized logging control
       - Append-Only: Always append to existing log file using `seekToEndOfFile()` to preserve history
       - Timestamp Prefix: Include `[\(Date())]` at start of each message for chronological tracking
       - Component Identification: Prefix messages with component name (e.g., "ProviderManager:", "OpenCodeZen:")
       - Guard with #if DEBUG: Completely removes debug code from Release builds automatically
       - Pattern: File-based logging to /tmp/provider_debug.log with graceful silent failure
       - Safety: Use `try?` for file operations to avoid crashing if log file is inaccessible
   - **Dynamic Binary Discovery for External Tools**:
      - Hardcoded Path Problem: Single hardcoded path like `~/.opencode/bin/opencode` fails when users install via Homebrew or other methods
      - Multi-Strategy Search: Implement fallback search pattern with multiple discovery methods
      - Search Priority: 1) 'which opencode' in current PATH, 2) Login shell PATH (captures shell profile additions), 3) Common install locations (Homebrew, OpenCode default, pip/pipx)
      - Lazy Loading: Cache binary path on first successful discovery to avoid repeated searches
      - Debug Logging: Show which discovery method found the binary for troubleshooting
      - Example Fix: OpenCodeZenProvider changed from hardcoded path to dynamic multi-strategy search
      - Pattern: Replace single path with search function that tries multiple locations in priority order
   - **Multi-Strategy Auth File Discovery**:
      - Single Path Problem: Hardcoded `~/.local/share/opencode/auth.json` fails when users have different OpenCode configurations
      - XDG Standard Support: Respect $XDG_DATA_HOME environment variable when set (highest priority)
      - Fallback Priority: 1) $XDG_DATA_HOME/opencode/auth.json (if set), 2) ~/.local/share/opencode/auth.json (XDG default), 3) ~/Library/Application Support/opencode/auth.json (macOS convention)
      - Path Tracking: Store `lastFoundAuthPath` to show users which file was loaded for troubleshooting
      - Sequential Try Pattern: Loop through paths and use first one that exists and is valid
      - Example Fix: TokenManager added getAuthFilePaths() function and sequential try-catch loop
      - Pattern: Define priority array of possible paths, try each in order, return first valid result
   - **Sparkle Auto-Relaunch for Menu Bar Apps**:
      - LSUIElement Special Case: Menu bar apps (LSUIElement=true) don't automatically relaunch after Sparkle updates
      - Missing Relaunch: After update completes, app quits but doesn't restart, requiring manual launch
      - Solution: Add SUAllowsAutomaticUpdates to Info.plist and implement SPUUpdaterDelegate with lifecycle hooks
      - Required Methods: `updaterWillRelaunchApplication(_:)` and `updaterDidRelaunchApplication(_:)` in AppDelegate
      - Pattern: Sparkle framework handles restart automatically when delegate is properly configured
      - Example Fix: Added SUAllowsAutomaticUpdates=Yes to Info.plist and SPUUpdaterDelegate implementation
   - **Dependency Version Pinning for CI Compatibility**:
      - Experimental Feature Error: Newer package versions may require Swift experimental features not available in CI
      - Example Failure: ArgumentParser 1.7.0 required 'AccessLevelOnImport' experimental feature
      - CI Compatibility Solution: Pin to specific version using exactVersion instead of upToNextMajorVersion
      - Pattern: Use exact version in Package.resolved to ensure consistent builds across environments
      - Trade-off: Sacrifice latest features for build stability, update pinning only after verifying CI compatibility
      - Example Fix: Pinned ArgumentParser from 1.7.0 to 1.5.0 in Package.resolved
   - **Subscription Preset Comparison**:
       - Name Uniqueness Problem: Comparing subscription presets by name can fail when multiple presets share the same name
       - Example Failure: 'MAX' preset exists at both $100 and $200 cost levels, causing incorrect selection
       - Solution: Compare by numeric cost value instead of string name to ensure unique identification
       - Pattern: Use `cost` field or numeric identifier when comparing/selecting presets with potentially duplicate names
       - Context: Menu item selection relies on accurate preset matching for correct pricing display
   - **Copilot Quota Reset Date Tracking**:
        - Missing Reset Date: Copilot quota reset date wasn't tracked in DetailedUsage struct
        - Usage Prediction Impact: Without reset date, cannot accurately predict end-of-month quota usage
        - Fix: Add `copilotQuotaResetDateUTC` field to DetailedUsage model and update encoding/decoding
        - Pattern: When adding provider-specific data, ensure Codable conformance includes all new fields
        - Example: CopilotProvider now passes `usage.quotaResetDateUTC` to DetailedUsage constructor
    - **Test Model Alignment**:
         - Test-Implementation Mismatch: Tests using wrong billing model (payAsYouGo vs quotaBased) cause assertion failures
         - Example Failure: CodexProviderTests used payAsYouGo model while provider is quotaBased
         - Fix: Update test models to match actual provider implementation (remaining/entitlement vs utilization/cost)
         - Pattern: Verify test models match provider type when fixing provider bugs
         - Validation: Check both assertions and expected field types (Int vs Double, optional vs required)
     - **Code Signing Timestamp Service Retry**:
        - Timestamp Service Failures: `codesign --timestamp` may fail due to external service unavailability in CI/CD
        - Build Impact: Xcode archive and code signing operations fail when timestamp service is down
        - Solution: Implement retry logic with exponential delays for both build and signing stages
        - Retry Pattern:
          - Build: Max 3 retries with 30s delay between attempts
          - Signing: Max 3 retries with 10s delay between attempts
          - Function: Create `sign_with_retry()` wrapper function for all codesign calls
        - Example: GitHub Actions workflow uses for-loop with attempt counter and sleep delays
        - Benefit: Improves CI/CD reliability when external timestamp services experience temporary outages
    - **Common Deduplication Logic for Multi-Account Providers**:
        - Code Duplication: Each provider had its own `dedupeCandidates` method with identical logic
        - Maintenance Burden: Changes require updating 4+ provider files separately (Claude, Codex, Copilot, Gemini)
        - Fix: Extract shared `CandidateDedupe.merge()` helper to `ProviderResult.swift`
        - Generic Implementation: Use closures for `accountId`, `isSameUsage`, `priority` to make it type-agnostic
        - Pattern: Replace private methods with shared generic helpers for cross-provider operations
        - Example: All 4 providers now call `CandidateDedupe.merge()` instead of their own implementations
    - **File Readability Check Before Access**:
        - Silent Failures: Files exist but are not readable due to permissions cause runtime errors
        - Missing Validation: `FileManager.fileExists()` only checks existence, not readability
        - Fix: Add `isReadableFile(atPath:)` check before attempting to read file contents
        - Safety Pattern: `guard fileManager.fileExists(atPath: path), guard fileManager.isReadableFile(atPath: path)`
        - Warning Logging: Log warning when file is not readable for troubleshooting
        - Implementation: Add check in `TokenManager.swift` for Gemini OAuth, Codex auth, Antigravity accounts
        - Benefit: Prevents crashes and provides better error messages for permission issues
 
    <!-- opencode:reflection:end -->
