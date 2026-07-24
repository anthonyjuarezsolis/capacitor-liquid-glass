import { Capacitor } from '@capacitor/core';

import type { LiquidGlassPlugin, ShowTabBarOptions, TabBarBounds } from './definitions';

/**
 * Keeps the native tab bar glued to an HTML element when `containerElement` is
 * passed to `showTabBar`. Mirrors the measure-and-observe approach of
 * `@capacitor/google-maps`, but adapted for a **fixed overlay** rather than an
 * inline view:
 *
 *  - Google Maps (iOS) reparents its native view into a `WKChildScrollView` so
 *    it scrolls *with* page content. A tab bar must stay glued to the element's
 *    on-screen rect, so we instead push the rect to native, which positions an
 *    on-top overlay via Auto Layout constraints (never `setFrame` — see the
 *    iOS 26 Liquid Glass notes in `LiquidGlassTabBarOverlay.swift`).
 *  - We re-sync on `ResizeObserver` + `scroll` (capture phase, catches nested
 *    scroll containers) + `resize`/`orientationchange` + `visualViewport`
 *    (keyboard / browser-chrome / pinch-zoom), all **coalesced through a single
 *    `requestAnimationFrame`** so a 120 Hz scroll fires at most one bridge call
 *    per frame (the Maps plugin's lack of this is its main jitter source).
 *
 * When `containerElement` is omitted, this is a transparent pass-through to the
 * native bottom-pinned behaviour — zero regression.
 */
export class TabBarBinder {
  private element: HTMLElement | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private mutationObserver: MutationObserver | null = null;
  private rafId: number | null = null;
  /** Last rect pushed to native — skip redundant bridge calls when unchanged. */
  private lastSent: TabBarBounds | null = null;
  /**
   * Bumped on every teardown. Async work (the `measure` retry loop, the awaits
   * in `showTabBar`) snapshots it and bails if a newer call superseded it —
   * prevents a slow first measurement from clobbering a second `showTabBar`.
   */
  private generation = 0;

  // ── Auto-hide state (anchored mode) ─────────────────────────────────────
  //
  // With an anchor bound, the native bar mirrors the anchor's LIFECYCLE, not
  // just its geometry: anchor collapsed/detached/invisible → native hide;
  // anchor covered by DOM (modal backdrop, drawer — the z-index occlusion an
  // HTML bar would get for free) → native hide; anchor back → native re-show
  // with the cached config. Overlays therefore no longer need to coordinate
  // show/hide manually.

  /** Options (element-stripped) cached for auto re-show. */
  private cachedOptions: ShowTabBarOptions | null = null;
  /** True while the bar is hidden by the binder (not by the consumer). */
  private autoHidden = false;
  /** Candidate state pending 2-frame confirmation (anti-flap). */
  private flapCandidate: 'hide' | 'show' | null = null;
  /** Overlays that legitimately float above the bar without hiding it. */
  private static readonly OCCLUSION_WHITELIST = ['.sui-toast-stack'];
  /** Consumer-provided additions (occlusionWhitelist option). */
  private extraWhitelist: string[] = [];

  /** Stable identity so `removeEventListener` actually detaches the listeners. */
  private readonly onReflow = (): void => this.scheduleSync();

  constructor(private readonly native: LiquidGlassPlugin) {}

  async showTabBar(options: ShowTabBarOptions): Promise<void> {
    // A fresh call always supersedes any previous binding (bumps generation).
    this.teardown();
    const gen = this.generation;

    const target = options.containerElement;
    const wantsBinding = Capacitor.getPlatform() === 'ios' && target != null;

    if (!wantsBinding) {
      return this.native.showTabBar(this.stripElement(options));
    }

    const element = this.resolve(target as string | HTMLElement);
    if (!element) {
      // Selector didn't match — fall back to bottom-pinned instead of throwing.
      return this.native.showTabBar(this.stripElement(options));
    }

    this.element = element;
    this.extraWhitelist = options.occlusionWhitelist ?? [];
    this.cachedOptions = this.stripElement(options);
    const bounds = await this.measure(element, gen);
    if (gen !== this.generation) return; // superseded while measuring

    if (bounds.width === 0 || bounds.height === 0) {
      /* Anchor unusable at bind time (hidden route, display:none). Instead of
         the old bottom-pinned fallback — which floated a bar over screens that
         deliberately have none — start auto-hidden and keep observing: the
         MutationObserver re-shows the bar the moment the anchor becomes real. */
      this.autoHidden = true;
      await this.native.hideTabBar();
      if (gen !== this.generation) return;
      this.observe(element);
      return;
    }

    if (options.reparent) {
      /* Reparent: el bar vive DENTRO del scroll view del slot — sigue su
         geometría solo y el z-order del DOM lo tapa/destapa. Ni observers ni
         oclusión ni setTabBarBounds: la plataforma hace todo. */
      await this.native.showTabBar({ ...this.cachedOptions, bounds, reparent: true });
      return;
    }

    await this.native.showTabBar({ ...this.cachedOptions, bounds });
    if (gen !== this.generation) return; // superseded while the bridge call ran

    this.lastSent = bounds;
    this.observe(element);
  }

  async hideTabBar(): Promise<void> {
    this.teardown();
    return this.native.hideTabBar();
  }

  /** Keeps the cached config in sync so an auto re-show restores the tab the
      user actually had selected (facade routes `setSelectedTab` through here). */
  noteSelectedIndex(index: number): void {
    if (this.cachedOptions) this.cachedOptions = { ...this.cachedOptions, selectedIndex: index };
  }

  // --- internals -----------------------------------------------------------

  /** Removes the (possibly non-serializable) element ref before crossing the bridge. */
  private stripElement(options: ShowTabBarOptions): ShowTabBarOptions {
    const { containerElement: _el, occlusionWhitelist: _wl, ...rest } = options;
    void _el;
    void _wl;
    return rest;
  }

  private resolve(target: string | HTMLElement): HTMLElement | null {
    if (typeof target !== 'string') return target;
    return document.getElementById(target) ?? document.querySelector<HTMLElement>(target);
  }

  private rect(element: HTMLElement): TabBarBounds {
    const r = element.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  }

  /**
   * Retry until the element has a non-zero width AND height (guards against
   * pre-layout reads). Bails early if a newer `showTabBar`/`hideTabBar` bumped
   * the generation, so a stale interval can't outlive the call that started it.
   * If it still measures 0 after ~3s, resolves with the zero rect (native falls
   * back to bottom-pinned) and warns so the misconfig is visible.
   */
  private measure(element: HTMLElement, gen: number): Promise<TabBarBounds> {
    const valid = (b: TabBarBounds): boolean => b.width !== 0 && b.height !== 0;
    return new Promise((resolve) => {
      let bounds = this.rect(element);
      if (valid(bounds)) {
        resolve(bounds);
        return;
      }
      let retries = 0;
      const id = setInterval(() => {
        if (gen !== this.generation) {
          clearInterval(id);
          resolve(bounds);
          return;
        }
        bounds = this.rect(element);
        retries++;
        if (valid(bounds) || retries >= 30) {
          clearInterval(id);
          if (!valid(bounds)) {
            console.warn(
              '[LiquidGlass] containerElement still measures 0 after 3s — the native bar will fall back to bottom-pinned.',
            );
          }
          resolve(bounds);
        }
      }, 100);
    });
  }

  private observe(element: HTMLElement): void {
    if (typeof ResizeObserver !== 'undefined') {
      this.resizeObserver = new ResizeObserver(this.onReflow);
      this.resizeObserver.observe(element);
    }
    // Position changes a ResizeObserver won't catch. Capture phase so scrolls in
    // nested `overflow:auto` containers (which don't bubble to window) re-sync too.
    window.addEventListener('scroll', this.onReflow, { passive: true, capture: true });
    window.addEventListener('resize', this.onReflow, { passive: true });
    window.addEventListener('orientationchange', this.onReflow, { passive: true });
    const vv = window.visualViewport;
    if (vv) {
      vv.addEventListener('resize', this.onReflow);
      vv.addEventListener('scroll', this.onReflow);
    }
    // DOM occlusion (a modal/backdrop mounting on top of the anchor) fires none
    // of the above. childList-only mutations, coalesced through the same rAF,
    // are the cheapest reliable trigger (IntersectionObserver v2 is
    // Chromium-only and the binding is iOS/WebKit).
    if (typeof MutationObserver !== 'undefined') {
      this.mutationObserver = new MutationObserver(this.onReflow);
      this.mutationObserver.observe(document.body, { childList: true, subtree: true });
    }
  }

  private scheduleSync(): void {
    if (this.rafId != null) return;
    this.rafId = requestAnimationFrame(() => {
      this.rafId = null;
      const element = this.element;
      if (!element) return;
      const bounds = this.rect(element);
      const usable =
        element.isConnected &&
        bounds.width > 0 &&
        bounds.height > 0 &&
        this.isVisuallyShown(element) &&
        !this.isOccluded(element, bounds);

      if (!usable) {
        if (this.autoHidden) return;
        /* Anti-flap: confirmar el estado en un segundo frame antes de actuar
           (transiciones de layout pueden dar una lectura intermedia). */
        if (this.flapCandidate !== 'hide') {
          this.flapCandidate = 'hide';
          this.scheduleSync();
          return;
        }
        this.flapCandidate = null;
        this.autoHidden = true;
        this.lastSent = null;
        void this.native.hideTabBar();
        return;
      }

      if (this.autoHidden) {
        if (this.flapCandidate !== 'show') {
          this.flapCandidate = 'show';
          this.scheduleSync();
          return;
        }
        this.flapCandidate = null;
        const opts = this.cachedOptions;
        if (!opts) return; // sin config cacheada no hay qué re-mostrar
        this.autoHidden = false;
        this.lastSent = bounds;
        void this.native.showTabBar({ ...opts, bounds });
        return;
      }

      this.flapCandidate = null;
      // Skip redundant bridge calls when the rect didn't actually move (e.g. a
      // scroll in an unrelated container, or a position:fixed element). Each
      // skipped call also saves a native `layoutIfNeeded`.
      if (this.sameRect(bounds, this.lastSent)) return;
      this.lastSent = bounds;
      void this.native.setTabBarBounds({ bounds });
    });
  }

  /** visibility/opacity hidden anchors keep a non-zero rect — check explicitly.
      `checkVisibility` ships in Safari 17.4+; fall back to computed style. */
  private isVisuallyShown(element: HTMLElement): boolean {
    const check = (element as { checkVisibility?: (o: object) => boolean }).checkVisibility;
    if (typeof check === 'function') {
      return check.call(element, { opacityProperty: true, visibilityProperty: true });
    }
    const cs = getComputedStyle(element);
    return cs.visibility !== 'hidden' && cs.opacity !== '0' && cs.display !== 'none';
  }

  /** Something covers the anchor's center (modal, drawer, backdrop) → treat as
      hidden, mirroring the z-index occlusion an HTML bar gets natively. Toasts
      and other whitelisted overlays float above the bar without hiding it. */
  private warnedUntestable = false;

  private isOccluded(element: HTMLElement, bounds: TabBarBounds): boolean {
    /* Anchors with pointer-events:none are invisible to elementFromPoint — the
       hit would be whatever sits BEHIND them, a guaranteed false positive that
       auto-hides the bar forever. Contract: keep the anchor hit-testable. If a
       consumer breaks it, degrade to geometry-only tracking (no occlusion). */
    if (getComputedStyle(element).pointerEvents === 'none') {
      if (!this.warnedUntestable) {
        this.warnedUntestable = true;
        console.warn(
          '[LiquidGlass] anchor has pointer-events:none — occlusion detection disabled. Keep the anchor hit-testable.',
        );
      }
      return false;
    }
    const cx = bounds.x + bounds.width / 2;
    const cy = bounds.y + bounds.height / 2;
    if (cx < 0 || cy < 0 || cx > window.innerWidth || cy > window.innerHeight) return true;
    const hit = document.elementFromPoint(cx, cy);
    if (!hit) return true;
    if (hit === element || element.contains(hit) || hit.contains(element)) return false;
    for (const sel of [...TabBarBinder.OCCLUSION_WHITELIST, ...this.extraWhitelist]) {
      if (hit.closest(sel)) return false;
    }
    return true;
  }

  private sameRect(a: TabBarBounds, b: TabBarBounds | null): boolean {
    if (!b) return false;
    return (
      Math.abs(a.x - b.x) < 0.5 &&
      Math.abs(a.y - b.y) < 0.5 &&
      Math.abs(a.width - b.width) < 0.5 &&
      Math.abs(a.height - b.height) < 0.5
    );
  }

  private teardown(): void {
    // Invalidate any in-flight measure/await chain from a previous call.
    this.generation++;
    this.lastSent = null;
    if (this.rafId != null) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
    this.mutationObserver?.disconnect();
    this.mutationObserver = null;
    this.autoHidden = false;
    this.flapCandidate = null;
    this.cachedOptions = null;
    this.extraWhitelist = [];
    // `capture` must match the add-time flag for removal to take effect.
    window.removeEventListener('scroll', this.onReflow, { capture: true });
    window.removeEventListener('resize', this.onReflow);
    window.removeEventListener('orientationchange', this.onReflow);
    const vv = window.visualViewport;
    if (vv) {
      vv.removeEventListener('resize', this.onReflow);
      vv.removeEventListener('scroll', this.onReflow);
    }
    this.element = null;
  }
}
