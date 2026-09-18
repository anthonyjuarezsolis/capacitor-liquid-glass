import Foundation
import Capacitor
import UIKit
import WebKit

@objc(LiquidGlassPlugin)
public class LiquidGlassPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "LiquidGlassPlugin"
    public let jsName = "LiquidGlass"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "showTabBar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hideTabBar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSelectedTab", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateTabBadge", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getTabBarLayout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTabBarBounds", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "showSearchBar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hideSearchBar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearSearchText", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setWebViewBackground", returnType: CAPPluginReturnPromise),
    ]

    private var tabBarOverlay: LiquidGlassTabBarOverlay?
    private var searchOverlay: LiquidGlassSearchOverlay?

    @objc func showTabBar(_ call: CAPPluginCall) {
        guard let rawItems = call.getArray("items") as? [[String: Any]] else {
            call.reject("items is required")
            return
        }
        let selectedIndex = call.getInt("selectedIndex") ?? 0
        let tintHex = call.getString("tintColor")
        let styleRaw = call.getString("tabBarStyle") ?? "default"
        // Optional binding rect. When present the bar is positioned to match an
        // HTML element instead of being pinned to the bottom (the JS layer
        // measures the element and injects this). Invalid/absent → bottom-pinned.
        let bounds = call.getObject("bounds").flatMap { Self.rect(from: $0) }
        // Reparent mode (spike 2026-06-14): insertar el bar DENTRO del
        // WKChildScrollView del slot → z-order del DOM real. Los binarios
        // viejos ignoran esta clave (degradación elegante garantizada).
        let reparent = call.getBool("reparent") ?? false

        let items = rawItems.compactMap { LiquidGlassTabItem(dictionary: $0) }
        guard !items.isEmpty else {
            call.reject("items cannot be empty")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentTabBar(items: items, selectedIndex: selectedIndex, tintHex: tintHex, styleRaw: styleRaw, bounds: bounds, reparent: reparent)
            call.resolve()
        }
    }

    @objc func setTabBarBounds(_ call: CAPPluginCall) {
        guard let boundsDict = call.getObject("bounds"), let rect = Self.rect(from: boundsDict) else {
            call.reject("bounds {x, y, width, height} is required")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.tabBarOverlay?.setBounds(rect)
            call.resolve()
        }
    }

    /// Parses a `{x, y, width, height}` JS object into a `CGRect`. Tolerates
    /// numbers arriving as `Double`, `Int` or `NSNumber` across the bridge.
    private static func rect(from dict: JSObject) -> CGRect? {
        func num(_ value: Any?) -> Double? {
            if let d = value as? Double { return d }
            if let n = value as? NSNumber { return n.doubleValue }
            if let i = value as? Int { return Double(i) }
            return nil
        }
        guard let x = num(dict["x"]), let y = num(dict["y"]),
              let w = num(dict["width"]), let h = num(dict["height"]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    @objc func hideTabBar(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.tabBarOverlay?.hide()
            call.resolve()
        }
    }

    @objc func updateTabBadge(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("id is required")
            return
        }
        let badge = call.getString("badge")

        DispatchQueue.main.async { [weak self] in
            self?.tabBarOverlay?.updateBadge(id: id, badge: badge)
            call.resolve()
        }
    }

    @objc func setSelectedTab(_ call: CAPPluginCall) {
        let index = call.getInt("index")
        let id = call.getString("id")

        DispatchQueue.main.async { [weak self] in
            guard let overlay = self?.tabBarOverlay else {
                call.reject("tab bar is not shown")
                return
            }
            if let index {
                overlay.setSelectedIndex(index)
            } else if let id {
                overlay.setSelected(id: id)
            }
            call.resolve()
        }
    }

    @objc func getTabBarLayout(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            let layout = self?.tabBarOverlay?.currentLayout() ?? (height: 0.0, bottomSafeArea: 0.0)
            call.resolve([
                "height": layout.height,
                "bottomSafeArea": layout.bottomSafeArea,
            ])
        }
    }

    // MARK: - Search Bar

    @objc func showSearchBar(_ call: CAPPluginCall) {
        let placeholder = call.getString("placeholder")
        let initialText = call.getString("initialText")
        let cancelText = call.getString("cancelText")
        let tintHex = call.getString("tintColor")
        let hideCancelButton = call.getBool("hideCancelButton") ?? false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentSearchBar(
                placeholder: placeholder,
                initialText: initialText,
                cancelText: cancelText,
                tintHex: tintHex,
                hideCancelButton: hideCancelButton
            )
            call.resolve()
        }
    }

    @objc func hideSearchBar(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.searchOverlay?.hide()
            call.resolve()
        }
    }

    /// El color que asoma detrás del documento: entre un `reload` y el primer
    /// paint del bundle nuevo el WKWebView pinta su propio `backgroundColor`
    /// (blanco por defecto — 3 frames medidos al aplicar una actualización en
    /// modo oscuro). La app lo llama cada vez que cambia de tema.
    @objc func setWebViewBackground(_ call: CAPPluginCall) {
        guard let hex = call.getString("color"), let color = UIColor(webViewHex: hex) else {
            call.reject("color (#RRGGBB) is required")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.bridge?.webView else { call.resolve(); return }
            webView.isOpaque = false
            webView.backgroundColor = color
            webView.scrollView.backgroundColor = color
            self?.bridge?.viewController?.view.backgroundColor = color
            call.resolve()
        }
    }

    @objc func clearSearchText(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.searchOverlay?.clearText()
            call.resolve()
        }
    }

    private func presentSearchBar(
        placeholder: String?,
        initialText: String?,
        cancelText: String?,
        tintHex: String?,
        hideCancelButton: Bool
    ) {
        guard let window = UIApplication.shared.capacitorWindow else { return }

        if searchOverlay == nil {
            let overlay = LiquidGlassSearchOverlay()
            overlay.delegate = self
            searchOverlay = overlay
        }

        searchOverlay?.configure(
            placeholder: placeholder,
            initialText: initialText,
            cancelText: cancelText,
            tintHex: tintHex,
            hideCancelButton: hideCancelButton
        )
        searchOverlay?.show(on: window)
    }

    private func presentTabBar(items: [LiquidGlassTabItem], selectedIndex: Int, tintHex: String?, styleRaw: String, bounds: CGRect?, reparent: Bool = false) {
        // CRÍTICO: usar `bridge?.viewController` (el VC que contiene el
        // WKWebView de Capacitor) en lugar del `rootViewController` del
        // window. iOS 26 aplica Liquid Glass automáticamente al UITabBar
        // solo cuando está en la jerarquía del VC del webview. El rootVC
        // del window puede ser un container distinto y romper el adopt.
        guard let hostVC = bridge?.viewController else { return }

        if tabBarOverlay == nil {
            let overlay = LiquidGlassTabBarOverlay()
            overlay.onTabSelected = { [weak self] index, id in
                self?.notifyListeners("tabSelected", data: ["index": index, "id": id])
            }
            overlay.onLayoutChanged = { [weak self] height, bottomSafeArea in
                self?.notifyListeners("tabBarLayoutChanged", data: [
                    "height": height,
                    "bottomSafeArea": bottomSafeArea,
                ])
            }
            tabBarOverlay = overlay
        }

        let style = LiquidGlassTabBarStyle(rawValue: styleRaw) ?? .default
        // Reparent: buscar el WKChildScrollView del slot y montar adentro.
        // Si el match falla (WebKit aún no materializó el scroll view, slot
        // ausente), fallback transparente al overlay clásico.
        var didReparent = false
        if reparent, let bounds, bounds.width > 0, bounds.height > 0,
           let webView = bridge?.webView as? WKWebView {
            // isa-swizzle (técnica KVO): la subclase solo overridea hitTest,
            // sin stored properties → seguro. Evita que la app tenga que
            // inyectar su propio WKWebView (módulo no visible al target App
            // con Xcode 26 explicit modules).
            if !(webView is LiquidGlassWebView) {
                object_setClass(webView, LiquidGlassWebView.self)
            }
        }
        if reparent, let bounds, bounds.width > 0, bounds.height > 0,
           let webView = bridge?.webView as? WKWebView {
            notifyListeners("tabBarDiag", data: ["msg": "reparent solicitado bounds=\(Int(bounds.width))x\(Int(bounds.height))"])
            if let sv = LiquidGlassReparent.findAndPrepareScrollView(
                in: webView,
                slotWidth: Int(round(bounds.width)),
                slotHeight: Int(round(bounds.height)),
                slotX: Int(round(bounds.origin.x)),
                slotY: Int(round(bounds.origin.y))
            ) {
                tabBarOverlay?.attachReparented(into: sv, hostVC: hostVC)
                didReparent = true
                CAPLog.print("⚡️ LiquidGlass: reparent OK (intento 0)")
                notifyListeners("tabBarDiag", data: ["msg": "reparent OK (intento 0)"])
            } else {
                // WebKit materializa el WKChildScrollView async — reintentar
                // con backoff mientras el bar corre en overlay clásico; al
                // encontrarlo se migra en caliente.
                CAPLog.print("⚡️ LiquidGlass: reparent sin match aún — reintentando")
                scheduleReparentRetry(bounds: bounds, hostVC: hostVC, attempt: 1)
            }
        }
        if !didReparent {
            tabBarOverlay?.detachReparented()
            // `bridge?.webView` is needed to convert the JS rect (viewport CSS px)
            // into the host VC's coordinate space when binding to an HTML element.
            tabBarOverlay?.attach(to: hostVC, bounds: bounds, webView: bridge?.webView)
        }
        tabBarOverlay?.configure(items: items, selectedIndex: selectedIndex, tintHex: tintHex, style: style)
        tabBarOverlay?.show()
    }

    private func scheduleReparentRetry(bounds: CGRect, hostVC: UIViewController, attempt: Int) {
        guard attempt <= 6 else {
            CAPLog.print("⚡️ LiquidGlass: reparent agotó reintentos — queda overlay clásico")
            var inventory: [String] = []
            if let webView = bridge?.webView as? WKWebView {
                inventory = LiquidGlassReparent.scrollViewInventory(in: webView)
            }
            notifyListeners("tabBarDiag", data: ["msg": "reparent AGOTADO. ScrollViews: \(inventory.joined(separator: " | "))"])
            return
        }
        let delay = 0.15 * pow(2.0, Double(attempt - 1)) // 0.15s … 4.8s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let overlay = self.tabBarOverlay, !overlay.isReparented,
                  let webView = self.bridge?.webView as? WKWebView else { return }
            if let sv = LiquidGlassReparent.findAndPrepareScrollView(
                in: webView,
                slotWidth: Int(round(bounds.width)),
                slotHeight: Int(round(bounds.height)),
                slotX: Int(round(bounds.origin.x)),
                slotY: Int(round(bounds.origin.y))
            ) {
                overlay.attachReparented(into: sv, hostVC: hostVC)
                CAPLog.print("⚡️ LiquidGlass: reparent OK (intento \(attempt))")
                self.notifyListeners("tabBarDiag", data: ["msg": "reparent OK (intento \(attempt))"])
            } else {
                self.scheduleReparentRetry(bounds: bounds, hostVC: hostVC, attempt: attempt + 1)
            }
        }
    }
}

// MARK: - LiquidGlassSearchOverlayDelegate
extension LiquidGlassPlugin: LiquidGlassSearchOverlayDelegate {
    func searchOverlayDidChangeText(_ text: String) {
        notifyListeners("searchTextChanged", data: ["text": text])
    }

    func searchOverlayDidSubmit(_ text: String) {
        notifyListeners("searchSubmitted", data: ["text": text])
    }

    func searchOverlayDidCancel() {
        notifyListeners("searchCancelled", data: [:])
    }
}

// MARK: - UIApplication helper
private extension UIApplication {
    var capacitorWindow: UIWindow? {
        return connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ??
            connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first
    }
}

private extension UIColor {
    convenience init?(webViewHex hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
