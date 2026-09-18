import { Capacitor, registerPlugin } from '@capacitor/core';

import type { LiquidGlassPlugin } from './definitions';
import { TabBarBinder } from './tab-bar-binder';

const native = registerPlugin<LiquidGlassPlugin>('LiquidGlass', {
  web: () => import('./web').then((m) => new m.LiquidGlassWeb()),
});

/**
 * Drives the HTML-element binding lifecycle (measure + observe) on top of the
 * native bridge. When `showTabBar` is called without `containerElement` it is a
 * transparent pass-through, so existing callers behave exactly as before.
 */
const binder = new TabBarBinder(native);

/**
 * Public plugin façade. Everything delegates straight to the native bridge
 * except `showTabBar`/`hideTabBar`, which route through {@link TabBarBinder} so
 * the optional `containerElement` binding works without any consumer wiring.
 */
const LiquidGlass: LiquidGlassPlugin = {
  showTabBar: (options) => binder.showTabBar(options),
  hideTabBar: () => binder.hideTabBar(),
  // iOS-only: the native method only exists on iOS. On Android the bridge would
  // throw "not implemented"; resolve quietly instead (the binding layer already
  // gates on getPlatform() === 'ios', this guards direct low-level callers).
  setTabBarBounds: (options) =>
    Capacitor.getPlatform() === 'ios' ? native.setTabBarBounds(options) : Promise.resolve(),
  setSelectedTab: (options) => {
    if (options.index != null) binder.noteSelectedIndex(options.index);
    return native.setSelectedTab(options);
  },
  updateTabBadge: (options) => native.updateTabBadge(options),
  getTabBarLayout: () => native.getTabBarLayout(),
  showSearchBar: (options) => native.showSearchBar(options),
  hideSearchBar: () => native.hideSearchBar(),
  clearSearchText: () => native.clearSearchText(),
  setWebViewBackground: (options) =>
    Capacitor.getPlatform() === 'ios' ? native.setWebViewBackground(options) : Promise.resolve(),
  // Preserve the overloaded signature for consumers (the bind keeps `this`).
  addListener: native.addListener.bind(native) as LiquidGlassPlugin['addListener'],
  removeAllListeners: () => native.removeAllListeners(),
};

export * from './definitions';
export { LiquidGlass };
