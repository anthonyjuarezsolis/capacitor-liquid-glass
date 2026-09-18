import { WebPlugin } from '@capacitor/core';

import type {
  LiquidGlassPlugin,
  SetSelectedTabOptions,
  SetTabBarBoundsOptions,
  ShowSearchBarOptions,
  ShowTabBarOptions,
  TabBarLayoutEvent,
  UpdateTabBadgeOptions,
  SetWebViewBackgroundOptions,
} from './definitions';

/**
 * Web fallback — real Liquid Glass requires native iOS 26. On the web we
 * resolve no-ops so the app can run in the browser during development; the
 * Angular shell is expected to render its own CSS glassmorphism tab bar when
 * `isNativePlatform()` is false.
 */
export class LiquidGlassWeb extends WebPlugin implements LiquidGlassPlugin {
  async showTabBar(_options: ShowTabBarOptions): Promise<void> {
    // no-op on web
  }

  async hideTabBar(): Promise<void> {
    // no-op on web
  }

  async setSelectedTab(_options: SetSelectedTabOptions): Promise<void> {
    // no-op on web
  }

  async updateTabBadge(_options: UpdateTabBadgeOptions): Promise<void> {
    // no-op on web
  }

  async getTabBarLayout(): Promise<TabBarLayoutEvent> {
    return { height: 0, bottomSafeArea: 0 };
  }

  async setTabBarBounds(_options: SetTabBarBoundsOptions): Promise<void> {
    // no-op on web — native-only positioning.
  }

  async showSearchBar(_options?: ShowSearchBarOptions): Promise<void> {
    // no-op on web — caller should render its own DOM search input.
  }

  async hideSearchBar(): Promise<void> {
    // no-op on web
  }

  async clearSearchText(): Promise<void> {
    // no-op on web
  }

  async setWebViewBackground(_options: SetWebViewBackgroundOptions): Promise<void> {
    // no-op on web
  }
}
