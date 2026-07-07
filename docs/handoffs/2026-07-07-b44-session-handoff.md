# B44 Session Handoff — 2026-07-07

> Source session input: 2026-07-06 user-reported screenshot ("only 1 delete row, click delete → app stuck at loading").
> Reads ~700 lines of test-isolation commits + B44 follow-up commits + B52 fix + anchor investigation.

## Working-Tree State Note

Two files show as uncommitted at session end (by user convention, not committed):

- `.gitignore` — added `.swarm/` and `*.pbxproj.bak*` rules. These are local dev tooling; this is a Token King *fork* not upstream, so the upstream-acceptable set differs.
- `CopilotMonitor/CopilotMonitor/Info.plist` — `GitCommitHash` was bumped by Xcode builds during the session. Resetting this is a non-event (next build will re-bump) and avoids carrying session-specific metadata.

Both are intentionally P3-stale per the project's pre-session rule: "Don't commit .gitignore or Info.plist changes." Don't treat the dirty `git status` as an outstanding action — it's the project's steady state.

## Branch Policy Note (intentional divergence)

This fork is intentionally **left behind `upstream/main`** (4+ commits at session end). Per project convention set at session start ("Don't merge upstream/main — would mix Token King's fork history with upstream's release commits"). We push only to `origin/main` (`smy126988-ai/token-king`). When the working tree needs to be clean from `upstream/main`'s perspective, run `git status -sb` and read the `[ahead N, behind M]` summary — both are correct for the fork's design.

## TL;DR

Two user-reported bugs:
1. **B44 follow-up: wrong key deleted + stuck loading** — duplicate warning UI only shows 1 row (pre-fix shows wrong key) and clicking it makes the app permanently stuck at loading.
2. **Result in production**: Total header shows ~¥464 for a kimi + kimi_cn pair when user only wants the CN ¥199 (the other key is "stale from when user used Global").

Root cause split into 3 layers (per fix-cycle):
- **Layer A (B44 初版)**: `findLikelyDuplicateSubscriptionKeys()` did `sorted().dropFirst()`, picking the wrong key (ASCII `'.' < '_'` made kimi.<id> sort before kimi_cn.<id>, then dropFirst kept kimi_cn — i.e. the user's selected CN).
- **Layer B (B44 follow-up)**: `displayTitle(formatter:)` called without `presets:` meant CN key's cnyCost was never consulted, falling back to 39 USD × rate ≈ ¥265 for the user's CN ¥199 row. User picked the row they thought was "the overseas one" and lost their ¥199 selection.
- **Layer C (anchor lost)**: Every action handler path (`cancelTracking` + `updateMultiProviderMenu`) leaves the menu's anchor separator (tag=0) missing in production on user click. After that, every `updateMultiProviderMenu` early-returns with "no separator found" → menu never rebuilds → loading spinner visible forever.

Layer A + B fixed at `d54b91b`. Layer C symptoms addressed at `b29ecff` + `9dd3453`. **Layer C root cause remains unclosed** (NSMenu tracking + NSAlert.runModal state-machine interaction is the strongest hypothesis, unverified without lldb).

## What Was Actually Fixed (per commit)

### Test-isolation family (B07-B15) — 5 commits
- `4d5792e` **B11** — `ProviderRegionTests` switches to isolated formatter + reads `providerQuotaOrder` directly (no `StatusBarController()` init needed)
- `4e6a13b` **B13** — `BraveSearchProviderTests` snapshots/restores all 10 keys
- `68fea73` **B15** — `KimiProviderTests.tearDown` re-calls `resetCachedAuthForTesting()`
- `0ad08a5` **B14 docs** — audit-confirmed safe (3 `.shared` usages are read-only)
- `0ad08a5` **B07/B08/B10 docs** — already-fixed-in-historical-commit

### StatusBarController health — 4 commits
- `123ef5f` **B45** — `fetchUsage` Task `@MainActor in` with `[weak self]` added (retain cycle)
- `a5de7f9` **B47/B48** — `killStaleOpenCodeStatsProcesses` async + `kill(2)` return-value check
- `73f1c19` docs B47/B48 ✅

### B44 chain (the actual user-reported bug) — 10 commits
- `f157639` — end-to-end data test + 4 `debugLog` observability (`[B44-followup]`)
- `822acc2` — print-on-test receipt (test failure mode doubles as receipt output)
- `b29ecff` — **anchor recovery**: `updateMultiProviderMenu` rebuilds via `setupMenu()` + rebinds `statusItem.menu` when anchor missing (was silent return)
- `337c19e` docs b29ecff
- `d54b91b` — Layer A + B fix: `findLikelyDuplicateSubscriptionGroups()` lists ALL keys (no `dropFirst`), UI renders one delete row per key, prices via `monthlyCost(forKey:inCurrency:.rmb,formatter:)` so `cnyCost` is consulted
- `b6b0ae1` docs d54b91b
- `7fcccb1` — **Layer C cleanup + B52 fix**: revert Priority 1 "order swap" no-op, refactor `removeDuplicateSubscription` to extract testable `performRemoveDuplicateSubscription(forKey:)`, fix duplicate grouping to be `(family, suffix)` (B52 — was treating email TLD as accountId suffix)
- `1fa5f16` docs 7fcccb1
- `9dd3453` — `[anchor-fp]` observability: 5 fingerprint log points (setupMenu / menuWillOpen / menuDidClose×2 / updateMultiProviderMenu×3) report `anchor=idx:N tag0-indices:[N] items:N`
- `44ae73e` docs 9dd3453 + lessons learned

## Test State at Session End

```
xcodebuild test
Executed 414 tests, with 19 tests skipped and 0 failures (0 unexpected) in ~10s
```

Skipped 19 are live-network integration tests (`XCTSkip` when no real credentials) — design intent.

### New tests added (this session, all pass)
| Test | Location | Catches |
| --- | --- | --- |
| `testCrossProviderDuplicatesListAllKeysNotJustOne` | `SubscriptionSettingsManagerIsolationTests` | Pre-fix `dropFirst` bug |
| `testCrossProviderDuplicateLabelUsesCNYForCNKey` | same | Pre-fix `displayTitle(formatter:)` no `presets:` |
| `testSameProviderSingleKeyNotFlaggedAsDuplicate` | same | False-positive regression |
| `testB44FollowUpEndToEndFlow` | same | Full 6-step data-layer round-trip |
| `testB44FollowUpPrintsMenuStateForScreenshotScenario` | same | Receipt + assertion combo; stdout shows actual rendered state |
| `testMenuRecoversWhenAnchorSeparatorIsMissing` | `StatusBarControllerTestingModeTests` | Layer C recovery path |
| `testRemoveDuplicateRebuildsMenuEndToEnd` | same | True e2e (exercises `performRemoveDuplicateSubscription`) |
| `testEmailStyleAccountIdsAreNotGroupedByTLD` | `SubscriptionSettingsManagerIsolationTests` | B52 (cross-family TLD grouping) |

The `testRemoveDuplicateRebuildsMenuEndToEnd` is the only **real e2e** (drives `performRemoveDuplicateSubscription` directly without mocking `NSAlert`). It pre-fix fails on step 1 or 5; post-fix passes.

## Live App State (verified manually)

New build (`HEAD: 44ae73e`) running at `/tmp/tk-derived/Build/Products/Debug/Token King.app`. Menu structure dump for the user's real data (`kimi.d7k + kimi_cn.d7k` pair):

```
[8]  [VIEW:NSView] 额度状态：¥1329/月
[9]  [VIEW:NSView] ⚠︎ 检测到 1 组重复订阅（Key 列表见下，单击删除）
[10] 🗑 删除 Allegretto (¥265/月)（Key: kimi.d7k367ol3dc8u37dqb9g）
[11] 🗑 删除 Allegretto (¥199/月)（Key: kimi_cn.d7k367ol3dc8u37dqb9g）
[12] ─────────────
```

`anchor-fp` logs confirm anchor stable at `idx:2` during refresh cycles. Only user clicks disturb it (Layer C unclosed).

## Outstanding (P2 — root-cause work requires lldb)

**B44 follow-up (anchor recovery)**: Why does the menu's anchor separator (tag=0) disappear after a user click?

Symptom-locked observations from `[anchor-fp]`:
- Always stable during refresh ticks and `setupMenu()` re-entry.
- Only transitions `idx:N` → `nil` during a real user click on a menu item.

Hypothesis (unverified): NSMenu's tracking loop, paired with `NSAlert.runModal()` inside the action handler, allows AppKit-internal state to touch `menu.items` after the cancelTracking signal. The cleanest verification path needs `lldb` with breakpoints on `-[NSMenu removeItem:]` / `removeItemAtIndex:` / `setItems:` plus AppleScript-accessibility clicks on a real status-bar icon.

Until then, Priority 2 recovery in `b29ecff` is additive (`silent return` → `setupMenu() + statusItem?.menu = menu`) and labeled as symptom-only in backlog.

## Backlog at End of Session

| State | Count | Items |
| --- | --- | --- |
| ✅ 已修 | 1 | B44 row updated end-to-end |
| 已诊断待修 | 4 | B39, B40 (multi-monitor, low-priority until multi-display setup), B46 (5-file TimeZone fallback), B49-B51 (LOW) |
| Pending investigation | 1 | Layer C anchor loss root cause (P2, requires lldb) |

`docs/backlog/bugs/README.md` row for B44 now contains the full 8-sub-cause narrative; future agents reading that row should be able to skip the 4-commit archaeology.

## Lessons Saved to Memory

`~/.claude/projects/-Users-simengyu/memory/行为偏好/no-op fix 不能 ship：commit 前自检 5 问.md` — 5-question pre-commit checklist derived from this session's "Priority 1 no-op shipped as fix" mistake. Origin session and links in the file header.

`~/.claude/projects/-Users-simengyu/memory/Token King_session_20260706.md` — appended with three "[critical lesson]" entries from this session (priority-1 no-op, data-layer ≠ UI behavior, debugLog > hypothesizing).

agentmemory MCP: `mem_mra39kdb_c9e4fb7b637b` (Type: fact, strength 7, "commit 前 5 问自检").

## Picks for Next Session

1. **B46 (MEDIUM, 5-file TimeZone fallback)** — small additive fix, follow the same commit-then-debugLog pattern as B44.
2. **B52 followups** — read provider family helpers (`ProviderProtocol.family`); audit whether all `.rawValue == xxx` usages go through `ProviderFamily`. The B52 fix exposes that `ProviderIdentifier(rawValue:)` is still used in production paths.
3. **Anchor root cause (P2)** — bring lldb script for `-[NSMenu removeItem:]`/`removeItemAtIndex:`/`setItems:`; bring a cliclick or AppleScript click harness; pay the accessibility-prep cost upfront.
