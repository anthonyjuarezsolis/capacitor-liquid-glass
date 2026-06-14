# Changelog

All notable changes to this project will be documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) • SemVer.

## [0.4.1] — 2026-06

### Fixed
- **CocoaPods install failed** (`No podspec found for AjuarezsoCapacitorLiquidGlass`). The podspec was misnamed `CapacitorLiquidGlass.podspec` since the first release; Capacitor derives the pod name from the package (`@ajuarezso/capacitor-liquid-glass` → `AjuarezsoCapacitorLiquidGlass`), so `pod install` couldn't find it. Renamed the podspec + `s.name` to match. SPM was unaffected (resolves via `Package.swift`). Thanks [@drolpi](https://github.com/drolpi) ([#2](https://github.com/anthonyjuarezsolis/capacitor-liquid-glass/pull/2)).

## [0.4.0] — 2026-06

### Added
- **TabBar → HTML element binding** ([#1](https://github.com/anthonyjuarezsolis/capacitor-liquid-glass/issues/1)). `showTabBar({ containerElement })` glues the native bar to the bounds of an element in your layout (id, selector, or `HTMLElement`) instead of pinning it to the bottom — same idea as the Capacitor Google Maps placeholder element. Re-syncs on resize/scroll/rotation/keyboard, coalesced through `requestAnimationFrame`.
- `setTabBarBounds({ bounds })` — low-level escape hatch to position the bar at an explicit rect.

### Notes
- iOS only; web/Android ignore `containerElement` and fall back to bottom-pinned.
- The bound element must include `env(safe-area-inset-bottom)` when sitting at the bottom edge, or the bar gets clipped (the native bar fills the element's exact rect).
- Default behaviour (no `containerElement`) is unchanged — bottom-pinned, byte-identical.

## [0.3.x] — 2026-05

### Added
- TabBar style variants: `'default'` | `'ultraThin'` | `'transparent'` | `'liquidGlass'`
- `getTabBarLayout()` returns `{ height, bottomSafeArea }` for content padding

## [0.2.0] — 2026-05

### Added
- Native Liquid Glass SearchBar overlay (`showSearchBar`, `hideSearchBar`, `clearSearchText`)
- Events: `searchTextChanged`, `searchSubmitted`, `searchCancelled`

## [0.1.0] — 2026-05

### Added
- Initial release: TabBar with Liquid Glass background
- iOS 26+ real `UIGlassEffect`, fallback to `UITabBar` on iOS 15-25
- API: `showTabBar`, `hideTabBar`, `setSelectedTab`, `updateTabBadge`
- Events: `tabSelected`, `tabBarLayoutChanged`
- Android: graceful no-op
