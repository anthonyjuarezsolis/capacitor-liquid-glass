import UIKit
import WebKit

/// Reparent mode (spike liquid-glass-lab 2026-06-14, validado en device):
/// el tab bar nativo se inserta DENTRO del `WKChildScrollView` que WebKit
/// materializa para un slot scrollable del DOM. Al vivir en el árbol de render
/// del WebView, **el z-order del DOM aplica de verdad**: un modal/drawer web
/// con z-index mayor tapa al bar visualmente, y el material Liquid Glass
/// sobrevive intacto (probado A/B contra overlay).
///
/// Receta del slot (lado JS): div con `overflow-y: scroll` + hijo de height
/// 200% → WebKit crea un WKChildScrollView cuyo contentSize mide (w, 2h).
/// El match se hace por ese contentSize.
public final class LiquidGlassAnchorRegistry {
    public static let shared = LiquidGlassAnchorRegistry()
    /// Vistas nativas ancladas al DOM que deben recibir taps (ver
    /// `LiquidGlassWebView.hitTest`).
    public var views: [UIView] = []
}

/// Subclase de WKWebView que rutea los taps a las vistas nativas ancladas.
/// WKWebView normalmente entrega TODO touch a WebKit (WKContentView) — una
/// subview nativa reparentada renderiza pero jamás recibe taps sin esto.
///
/// La app la inyecta por la vía oficial de Capacitor:
/// ```swift
/// class MainViewController: CAPBridgeViewController {
///   override open func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
///     LiquidGlassWebView(frame: frame, configuration: configuration)
///   }
/// }
/// ```
/// (+ el storyboard apuntando a `MainViewController`).
public final class LiquidGlassWebView: WKWebView {
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let original = super.hitTest(point, with: event)
        for v in LiquidGlassAnchorRegistry.shared.views {
            guard v.window != nil, !v.isHidden, v.superview != nil else { continue }
            let p = v.convert(point, from: self)
            guard v.bounds.contains(p) else { continue }
            return v.hitTest(p, with: event) ?? v
        }
        return original
    }
}

enum LiquidGlassReparent {
    /// Busca el WKChildScrollView cuyo contentSize matchea el slot (w exacto,
    /// h o h/2 por el hijo al 200%) y lo prepara para hospedar al bar:
    /// scroll apagado, sin cancelación de touches y sin clipping en toda la
    /// cadena hasta el WebView (el glass del estado pressed desborda el rect).
    static func findAndPrepareScrollView(in webView: WKWebView, slotWidth: Int, slotHeight: Int) -> UIScrollView? {
        webView.scrollView.delaysContentTouches = false
        webView.scrollView.canCancelContentTouches = false

        var target: UIScrollView?
        for sub in allSubviews(of: webView) {
            guard let sv = sub as? UIScrollView, sv !== webView.scrollView else { continue }
            let cs = sv.contentSize
            if Int(round(cs.width)) == slotWidth,
               Int(round(cs.height / 2)) == slotHeight || Int(round(cs.height)) == slotHeight {
                target = sv
                break
            }
        }
        guard let sv = target else { return nil }

        sv.isScrollEnabled = false
        sv.panGestureRecognizer.isEnabled = false
        sv.canCancelContentTouches = false
        sv.delaysContentTouches = false
        sv.contentSize = sv.bounds.size
        sv.clipsToBounds = false
        var ancestor: UIView? = sv.superview
        while let a = ancestor, a !== webView {
            a.clipsToBounds = false
            ancestor = a.superview
        }
        return sv
    }

    private static func allSubviews(of view: UIView) -> [UIView] {
        var result: [UIView] = []
        for sub in view.subviews {
            result.append(sub)
            result.append(contentsOf: allSubviews(of: sub))
        }
        return result
    }
}
