import UIKit

struct LiquidGlassTabItem {
    let id: String
    let label: String
    let sfSymbol: String
    let badge: String?

    init?(dictionary: [String: Any]) {
        guard
            let id = dictionary["id"] as? String,
            let label = dictionary["label"] as? String,
            let sfSymbol = dictionary["sfSymbol"] as? String
        else {
            return nil
        }
        self.id = id
        self.label = label
        self.sfSymbol = sfSymbol
        self.badge = dictionary["badge"] as? String
    }
}

/// Visual style of the tab bar background.
enum LiquidGlassTabBarStyle: String {
    /// Translucent blurred — adopta Liquid Glass automáticamente en iOS 26+
    /// cuando el binario está linkeado contra el SDK iOS 26 (Xcode 26+).
    case `default`
    /// Minimal blur (`systemUltraThinMaterial`) — más ver-through que default.
    /// NOTA: este override CANCELA el adopt automático de Liquid Glass.
    case ultraThin
    /// No background, no blur — content behind se ve completo.
    /// NOTA: este override CANCELA el adopt automático de Liquid Glass.
    case transparent
    /// Liquid Glass nativo iOS 26 — alias funcional de `.default`. Se mantiene
    /// como case separado para semántica explícita en el consumer ("este
    /// layout pide específicamente Liquid Glass, no fallback genérico").
    case liquidGlass
}

/// Tab bar flotante que adopta iOS 26 Liquid Glass automáticamente cuando la
/// app se compila contra el SDK iOS 26.
///
/// **Decisión arquitectónica crítica**: este view controller se adjunta como
/// CHILD del view controller que contiene el WKWebView de Capacitor
/// (`bridge?.viewController`), y el `UITabBar` vive como subview de
/// `self.view`. Esto crea el view controller hierarchy completo que iOS 26
/// necesita para aplicar el material Liquid Glass automáticamente al
/// UITabBar.
///
/// Por qué NO usar `window.rootViewController`: en Capacitor el rootVC del
/// window puede ser un container distinto al VC del webview. iOS 26 solo
/// aplica Liquid Glass auto cuando el UITabBar vive en la jerarquía del VC
/// que tiene el webview activo. Agregarlo al rootVC del window puede
/// romper el auto-adopt y dejarlo con material translúcido genérico opaco
/// (no el real de Music / App Store).
///
/// Patrón inspirado en `stay-liquid` (alistairheath/stay-liquid GitHub).
final class LiquidGlassTabBarOverlay: UIViewController {

    // Public callbacks
    var onTabSelected: ((Int, String) -> Void)?
    var onLayoutChanged: ((Double, Double) -> Void)?

    // Internal state
    private let tabBar = UITabBar()
    private var items: [LiquidGlassTabItem] = []
    private weak var hostVC: UIViewController?
    /// WKWebView of the Capacitor bridge — used to convert the JS rect (viewport
    /// CSS px) into the host VC's coordinate space when bound to an HTML element.
    private weak var webView: UIView?

    /// Currently-active container constraints (bottom-pinned OR bound), so a
    /// re-`attach`/mode-switch can deactivate the previous set cleanly.
    private var activeConstraints: [NSLayoutConstraint] = []
    /// Mutable bound-mode geometry. Kept as properties so `setBounds` mutates
    /// `.constant` (no detach/reattach → VC hierarchy stays intact and the iOS
    /// 26 Liquid Glass auto-adopt is never re-triggered/lost).
    private var boundTop: NSLayoutConstraint?
    private var boundLeading: NSLayoutConstraint?
    private var boundWidth: NSLayoutConstraint?
    private var boundHeight: NSLayoutConstraint?
    /// `true` when the container tracks an HTML element rect; `false` when
    /// pinned to the bottom of the host (default).
    private var isBoundMode = false
    /// `true` cuando el bar vive reparentado DENTRO del WKChildScrollView del
    /// slot (z-order del DOM real). En este modo no hay constraints contra el
    /// host: frame + autoresizing dentro del scroll view (patrón del spike).
    private(set) var isReparented = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // Background transparente. El `self.view` está sizado SOLO al rect
        // del tab bar (leading/trailing/bottom al hostVC, sin top — la
        // altura la determina el intrinsic content size del UITabBar dentro).
        // Por eso NO necesitamos `hitTest` override: el view en sí solo
        // existe sobre el área de la pill, los taps fuera no llegan.
        view.backgroundColor = .clear

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self

        // CRÍTICO: NO setear appearance acá. iOS 26 adopta Liquid Glass
        // automáticamente SOLO si el UITabBar mantiene su appearance default
        // intacto. Tocar `standardAppearance` / `scrollEdgeAppearance` en
        // CUALQUIER forma — incluso con `configureWithDefaultBackground()` —
        // anula el adopt y deja un material translúcido genérico opaco.
        // Solo los overrides intencionales (.ultraThin, .transparent) tocan
        // el appearance, vía `applyAppearance(...)` desde `configure(...)`.

        view.addSubview(tabBar)

        // UITabBar ocupa TODO el self.view — el view es del tamaño exacto
        // de la pill gracias a las constraints del attach() (sin top).
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Adjunta este view controller como child del view controller que
    /// contiene el WKWebView de Capacitor (`bridge?.viewController`).
    ///
    /// - `bounds == nil` → **bottom-pinned** (comportamiento default histórico):
    ///   leading/trailing/bottom al host, sin top — la altura sale del intrinsic
    ///   content size del UITabBar (~50pt + safe-area-bottom).
    /// - `bounds != nil` (y válido) → **bound mode**: el container se posiciona
    ///   para coincidir con el rect de un elemento HTML, vía constraints
    ///   mutables top/leading/width/height (NUNCA `setFrame` — ver `setBounds`).
    ///
    /// Idempotente respecto al parenting: si ya es child del mismo host no
    /// re-adjunta, pero SÍ re-evalúa el layout (permite cambiar de modo o de
    /// rect entre llamadas a `showTabBar`).
    func attach(to hostVC: UIViewController?, bounds: CGRect?, webView: UIView?) {
        guard let hostVC else { return }
        self.webView = webView

        let wantsBound = bounds.map { $0.width > 0 && $0.height > 0 } ?? false

        // No-op idempotente del PATH DEFAULT (bottom-pinned): re-mostrar el bar
        // en el MISMO host sin binding (re-config de badge / cambio de route /
        // liberación de modal — el consumer lo dispara agresivamente) debe NO
        // tocar el layout del container, exactamente como antes de que existiera
        // bound mode. Sin este early-return cada re-llamada haría
        // deactivate+activate de las 3 constraints + un tabBarLayoutChanged de
        // más (regresión detectada en review). Solo aplica cuando ya estamos
        // bottom-pinned con constraints activas y NO se pide binding.
        if self.parent === hostVC, !wantsBound, !isBoundMode, !activeConstraints.isEmpty {
            return
        }

        if self.parent !== hostVC {
            // Si está adjuntado a otro VC (cambio de host entre sesiones),
            // detachar primero antes de re-adjuntar. Reseteamos TODO el estado
            // de modo/constraints para no quedar apuntando a constraints muertas
            // del host viejo (defensa en profundidad — review).
            if self.parent != nil {
                NSLayoutConstraint.deactivate(activeConstraints)
                activeConstraints = []
                boundTop = nil; boundLeading = nil; boundWidth = nil; boundHeight = nil
                isBoundMode = false
                self.willMove(toParent: nil)
                self.view.removeFromSuperview()
                self.removeFromParent()
            }
            hostVC.addChild(self)
            hostVC.view.addSubview(self.view)
            self.view.translatesAutoresizingMaskIntoConstraints = false
            // CRÍTICO: `didMove(toParent:)` ANTES de activar constraints. iOS 26
            // ejecuta el primer layout pass al didMove; tener el parenting
            // completo antes de que el sistema mida el UITabBar es lo que el
            // heurístico de Liquid Glass auto-adopt espera (patrón stay-liquid).
            self.didMove(toParent: hostVC)
        }
        self.hostVC = hostVC

        // Idempotencia post-reparent: si venimos de detachReparented() el view
        // quedó FUERA de la jerarquía con el parent VC intacto — sin este
        // re-add, activar constraints abajo crashea con "no common ancestor"
        // (crash real 2026-07-24 al cambiar de rol).
        if view.superview !== hostVC.view {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            hostVC.view.addSubview(view)
        }

        // `width > 0 && height > 0` es obligatorio: un container medido en 0×0 en
        // el primer layout pass es la única forma realista de PERDER el adopt de
        // Liquid Glass. Si el rect llega vacío caemos a bottom-pinned y el
        // siguiente `setBounds` con rect válido cambia a bound mode.
        if let bounds, wantsBound {
            applyBoundConstraints(bounds, hostVC: hostVC)
        } else {
            applyBottomPinned(hostVC: hostVC)
        }
        emitLayout()
    }

    /// Reparent mode (spike 2026-06-14): el view del overlay se inserta DENTRO
    /// del WKChildScrollView del slot → el z-order del DOM tapa/destapa el bar
    /// naturalmente (modales, drawers). Frame + autoresizing, sin constraints
    /// contra el host (árboles distintos). El VC sigue siendo child del host
    /// para conservar la jerarquía que iOS 26 espera para el adopt del glass.
    func attachReparented(into scrollView: UIScrollView, hostVC: UIViewController?) {
        guard let hostVC else { return }
        // Salir de cualquier modo previo (overlay bottom-pinned o bound).
        NSLayoutConstraint.deactivate(activeConstraints)
        activeConstraints = []
        boundTop = nil; boundLeading = nil; boundWidth = nil; boundHeight = nil
        isBoundMode = false

        if self.parent !== hostVC {
            if self.parent != nil {
                self.willMove(toParent: nil)
                self.view.removeFromSuperview()
                self.removeFromParent()
            }
            hostVC.addChild(self)
        }
        self.hostVC = hostVC

        // Dentro del scroll view: frame lleno + autoresizing (patrón del lab).
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = scrollView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.clipsToBounds = false
        scrollView.addSubview(view)
        if self.parent === hostVC { self.didMove(toParent: hostVC) }

        isReparented = true
        // Registrar para el hitTest del LiquidGlassWebView (taps).
        if !LiquidGlassAnchorRegistry.shared.views.contains(where: { $0 === view }) {
            LiquidGlassAnchorRegistry.shared.views.append(view)
        }
        emitLayout()
    }

    /// Sale del modo reparent (hide/teardown): desregistra del hitTest y
    /// desmonta el view del scroll view. El próximo attach normal re-parenta.
    func detachReparented() {
        guard isReparented else { return }
        isReparented = false
        LiquidGlassAnchorRegistry.shared.views.removeAll { $0 === view }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Default: container pegado al bottom del host, ancho completo, altura
    /// intrínseca del UITabBar. Idéntico al comportamiento previo a bound mode.
    private func applyBottomPinned(hostVC: UIViewController) {
        NSLayoutConstraint.deactivate(activeConstraints)
        boundTop = nil; boundLeading = nil; boundWidth = nil; boundHeight = nil
        isBoundMode = false
        let constraints = [
            view.leadingAnchor.constraint(equalTo: hostVC.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: hostVC.view.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: hostVC.view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        activeConstraints = constraints
    }

    /// Bound mode: posiciona el container al rect del elemento HTML mediante 4
    /// constraints mutables (top/leading/width/height). Se usan CONSTRAINTS y no
    /// `setFrame` a propósito: un `setFrame` pelea contra el Auto Layout pass del
    /// host y puede resolver a `.zero` justo en el primer layout pass que iOS 26
    /// inspecciona para el adopt → bar medido 0×0 → sin Liquid Glass.
    private func applyBoundConstraints(_ rect: CGRect, hostVC: UIViewController) {
        NSLayoutConstraint.deactivate(activeConstraints)
        isBoundMode = true
        let r = convertRectToHost(rect, hostVC: hostVC)
        let top = view.topAnchor.constraint(equalTo: hostVC.view.topAnchor, constant: r.origin.y)
        let leading = view.leadingAnchor.constraint(equalTo: hostVC.view.leadingAnchor, constant: r.origin.x)
        let width = view.widthAnchor.constraint(equalToConstant: r.size.width)
        let height = view.heightAnchor.constraint(equalToConstant: r.size.height)
        NSLayoutConstraint.activate([top, leading, width, height])
        boundTop = top; boundLeading = leading; boundWidth = width; boundHeight = height
        activeConstraints = [top, leading, width, height]
    }

    /// Reposiciona el container a un nuevo rect (driven por el ResizeObserver/
    /// scroll del lado JS). Solo muta `.constant` de las constraints existentes
    /// — sin re-parenting, sin tocar el UITabBar — envuelto en `CATransaction`
    /// con acciones implícitas desactivadas para que el movimiento sea snap (no
    /// un lerp animado que se vería como jitter al scrollear).
    func setBounds(_ rect: CGRect) {
        // Bar oculto (post hideTabBar): no mutar constraints ni emitir layout de
        // un bar que no se ve — evita estado inconsistente si un rAF en vuelo o
        // una llamada low-level llega tras el hide (review).
        guard !view.isHidden else { return }
        guard rect.width > 0, rect.height > 0, let hostVC else { return }
        // Primer rect válido tras un fallback a bottom-pinned → entrar a bound mode.
        guard isBoundMode, let boundTop, let boundLeading, let boundWidth, let boundHeight else {
            applyBoundConstraints(rect, hostVC: hostVC)
            emitLayout()
            return
        }
        let r = convertRectToHost(rect, hostVC: hostVC)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boundTop.constant = r.origin.y
        boundLeading.constant = r.origin.x
        boundWidth.constant = r.size.width
        boundHeight.constant = r.size.height
        hostVC.view.layoutIfNeeded()
        CATransaction.commit()
        emitLayout()
    }

    /// Convierte el rect COMPLETO (viewport CSS px == puntos del bounds del
    /// webView) al espacio de coordenadas del host VC. Convertir el rect entero
    /// — no solo el origen — cubre el caso de un webView insetado o escalado
    /// respecto al host (sin esto, origen y tamaño quedarían en espacios
    /// distintos; review). Con webView nil, fallback al rect crudo.
    private func convertRectToHost(_ rect: CGRect, hostVC: UIViewController) -> CGRect {
        guard let webView else { return rect }
        return webView.convert(rect, to: hostVC.view)
    }

    /// Aplica el appearance correspondiente al estilo solicitado.
    /// - `default` / `liquidGlass`: **NO-OP** — el UITabBar mantiene su
    ///   appearance default sin tocar para que iOS 26 aplique Liquid Glass
    ///   automáticamente. Cualquier touch al appearance (incluso
    ///   `configureWithDefaultBackground()`) rompe el auto-adopt.
    /// - `ultraThin`: blur mínimo `systemUltraThinMaterial` — más ver-through.
    ///   Override intencional que CANCELA Liquid Glass.
    /// - `transparent`: sin background ni blur — content behind se ve completo.
    ///   Override intencional que CANCELA Liquid Glass.
    private func applyAppearance(_ tabBar: UITabBar, style: LiquidGlassTabBarStyle) {
        // Early-return para los estilos que confían en el adopt automático
        // del sistema. Tocar appearance acá anula Liquid Glass.
        if style == .default || style == .liquidGlass { return }

        let appearance = UITabBarAppearance()
        switch style {
        case .default, .liquidGlass:
            // Unreachable — early-return arriba. Mantenido por exhaustividad
            // del switch sobre el enum.
            return
        case .ultraThin:
            appearance.configureWithDefaultBackground()
            appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            appearance.backgroundColor = UIColor.clear
        case .transparent:
            appearance.configureWithTransparentBackground()
            appearance.backgroundEffect = nil
            appearance.backgroundColor = UIColor.clear
            appearance.shadowColor = UIColor.clear
        }
        tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }
    }

    func configure(items: [LiquidGlassTabItem], selectedIndex: Int, tintHex: String?, style: LiquidGlassTabBarStyle) {
        // Preserve selection across re-configs (badge changes, etc.)
        let previousSelectedId: String? = tabBar.selectedItem.flatMap { current in
            self.items.indices.contains(current.tag) ? self.items[current.tag].id : nil
        }

        self.items = items

        // Re-aplica appearance por si el caller cambió de estilo en runtime.
        applyAppearance(tabBar, style: style)

        let uiItems: [UITabBarItem] = items.enumerated().map { index, item in
            let tab = UITabBarItem(
                title: item.label,
                image: UIImage(systemName: item.sfSymbol),
                tag: index
            )
            if let badge = item.badge, !badge.isEmpty {
                tab.badgeValue = badge
            }
            return tab
        }

        // CRÍTICO: setter directo `tabBar.items = ...` en lugar de
        // `tabBar.setItems(_, animated: false)`. En iOS 26 el método
        // `setItems(animated:)` toma un path interno distinto que puede
        // invalidar el adopt automático de Liquid Glass. El setter directo
        // es el que stay-liquid usa (línea 98 de su TabsBarOverlay).
        tabBar.items = uiItems

        if selectedIndex < 0 {
            tabBar.selectedItem = nil
        } else if let previousSelectedId, let restoreIdx = items.firstIndex(where: { $0.id == previousSelectedId }) {
            tabBar.selectedItem = uiItems[restoreIdx]
        } else if selectedIndex < uiItems.count {
            tabBar.selectedItem = uiItems[selectedIndex]
        }

        // tintColor aplicado siempre — el A/B test contra stay-liquid confirmó
        // que el adopt del material Liquid Glass NO se logra en este proyecto
        // independientemente del tintColor, así que mantenerlo solo aporta
        // identidad de marca (naranja brand) sin perder nada.
        if let tintHex, let tint = UIColor(hex: tintHex) {
            tabBar.tintColor = tint
        }
        emitLayout()
    }

    func updateBadge(id: String, badge: String?) {
        guard let tabBarItems = tabBar.items,
              let idx = items.firstIndex(where: { $0.id == id }),
              idx < tabBarItems.count else { return }
        let value = (badge?.isEmpty ?? true) ? nil : badge
        tabBarItems[idx].badgeValue = value
    }

    /// CRÍTICO: NO tocar `tabBar.alpha`, `tabBar.transform` ni `tabBar.isHidden`.
    /// iOS 26 inspecciona el UITabBar en el primer layout pass para decidir si
    /// adopta Liquid Glass. Si en ese momento el bar está con `alpha=0` o un
    /// `transform` distinto de `.identity`, el sistema descarta el adopt y NO
    /// re-evalúa aunque después vuelva a valores normales.
    ///
    /// Para animar la aparición/desaparición sin perder el adopt, se manipula
    /// `self.view.isHidden` (el contenedor del VC), no el UITabBar mismo.
    /// Patrón validado en stay-liquid (su `update()` simplemente hace
    /// `view.isHidden = !visible`).
    func show() {
        view.isHidden = false
        emitLayout()
    }

    func hide() {
        view.isHidden = true
    }

    func setSelectedIndex(_ index: Int) {
        guard let items = tabBar.items else { return }
        if index < 0 {
            tabBar.selectedItem = nil
            return
        }
        guard index < items.count else { return }
        tabBar.selectedItem = items[index]
    }

    func setSelected(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        setSelectedIndex(index)
    }

    func currentLayout() -> (height: Double, bottomSafeArea: Double) {
        tabBar.layoutIfNeeded()
        let bottomInset = tabBar.safeAreaInsets.bottom
        return (Double(tabBar.frame.height), Double(bottomInset))
    }

    private func emitLayout() {
        let layout = currentLayout()
        onLayoutChanged?(layout.height, layout.bottomSafeArea)
    }
}

// MARK: - UITabBarDelegate
extension LiquidGlassTabBarOverlay: UITabBarDelegate {
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard item.tag >= 0, item.tag < items.count else { return }
        let selected = items[item.tag]
        onTabSelected?(item.tag, selected.id)
    }
}

// MARK: - UIColor+hex
private extension UIColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let b = CGFloat(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
