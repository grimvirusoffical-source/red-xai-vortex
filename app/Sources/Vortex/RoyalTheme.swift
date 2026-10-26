import SwiftUI
import AppKit

/// Native visual tokens. The light palette respects the existing Appearance preference;
/// the default dark palette uses opaque surfaces so Reduce Transparency remains readable.
private struct RoyalPaletteEnvironmentKey: EnvironmentKey { static let defaultValue = "gold" }
extension EnvironmentValues {
    var royalPalette: String {
        get { self[RoyalPaletteEnvironmentKey.self] }
        set { self[RoyalPaletteEnvironmentKey.self] = newValue }
    }
}

enum RoyalTheme {
    static var palette: String { UserDefaults.standard.string(forKey: "royalPalette") ?? "gold" }
    static func adaptive(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
        })
    }
    static func color(_ dark: UInt32, _ light: UInt32, purple: UInt32, red: UInt32) -> Color {
        switch palette {
        case "purple": return adaptive(purple, purple)
        case "red": return adaptive(red, red)
        case "light": return adaptive(light, light)
        default: return adaptive(dark, light)
        }
    }
    /// Presets affect effective appearance only; the separate saved theme is never rewritten.
    static func colorScheme(palette: String, preference: String) -> ColorScheme? {
        switch palette {
        case "light": return .light
        case "purple", "red": return .dark
        default: return preference == "dark" ? .dark : preference == "light" ? .light : nil
        }
    }
    static var background: Color { color(0x101210, 0xF4F1E9, purple: 0x121018, red: 0x140F12) }
    static var sidebar: Color { color(0x151815, 0xECE8DE, purple: 0x191620, red: 0x1C1419) }
    static var surface: Color { color(0x1C201C, 0xFFFDFA, purple: 0x211C2A, red: 0x281C24) }
    static var elevated: Color { color(0x242A24, 0xF1EDE4, purple: 0x2B2436, red: 0x35232D) }
    static var text: Color { color(0xF4F1E8, 0x29271F, purple: 0xF3EDF8, red: 0xFAEFF2) }
    static var secondary: Color { color(0xAAAFA5, 0x68675E, purple: 0xB4A8C1, red: 0xC2ADB5) }
    static var accent: Color { color(0xDABD7B, 0x8B651E, purple: 0xC3A0F4, red: 0xF08494) }
    static var accentLight: Color { color(0xF2DCA4, 0xB58A3D, purple: 0xE4CEFF, red: 0xFFD2D9) }
    static var border: Color { color(0x414434, 0xCFC5AE, purple: 0x494050, red: 0x50313F) }
    static var selection: Color { color(0x343627, 0xDED4B9, purple: 0x3C2D4F, red: 0x472936) }
    // The independent existing Accent setting still means gold when chosen explicitly.
    static var gold: Color { adaptive(0xDABD7B, 0x8B651E) }
    static var line: Color { accent.opacity(0.19) }
    static let corner: CGFloat = 18
    static let contentWidth: CGFloat = 940
}

/// Quiet icon/secondary buttons retain a visible pressed state and keyboard focus.
struct RoyalButtonStyle: ButtonStyle {
    @Environment(\.royalPalette) private var palette
    var prominent = false
    var compact = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? RoyalTheme.background : RoyalTheme.text)
            .padding(.horizontal, compact ? 9 : 13).padding(.vertical, compact ? 7 : 10)
            .background(RoundedRectangle(cornerRadius: compact ? 9 : 11).fill(prominent ? RoyalTheme.accent : configuration.isPressed ? RoyalTheme.selection : RoyalTheme.elevated.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: compact ? 9 : 11).stroke(prominent ? RoyalTheme.accentLight.opacity(0.7) : RoyalTheme.line))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(nil, value: palette)
    }
}

struct RoyalMark: View {
    @Environment(\.royalPalette) private var palette
    var size: CGFloat = 30
    var body: some View {
        let _ = palette
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3).fill(LinearGradient(colors: [RoyalTheme.accentLight, RoyalTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkle").font(.system(size: size * 0.57, weight: .medium)).foregroundStyle(RoyalTheme.background)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A faceted jewel with familiar window-control symbols; no custom action replaces AppKit.
struct RoyalGemShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [.init(x: 0.28, y: 0), .init(x: 0.72, y: 0), .init(x: 1, y: 0.28), .init(x: 1, y: 0.72), .init(x: 0.72, y: 1), .init(x: 0.28, y: 1), .init(x: 0, y: 0.72), .init(x: 0, y: 0.28)]
        return Path { p in p.move(to: CGPoint(x: rect.width * points[0].x, y: rect.height * points[0].y)); for point in points.dropFirst() { p.addLine(to: CGPoint(x: rect.width * point.x, y: rect.height * point.y)) }; p.closeSubpath() }
    }
}

@MainActor final class RoyalWindowState: ObservableObject {
    weak var window: NSWindow?
    @Published var active = true
    @Published var fullScreen = false
    private var observers: [NSObjectProtocol] = []
    func attach(_ window: NSWindow) {
        guard self.window !== window else { update(); return }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        self.window = window
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = NSColor(RoyalTheme.background)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in Task { @MainActor in self?.update() } })
        }
        update()
    }
    func update() {
        guard let window else { return }
        active = window.isKeyWindow; fullScreen = window.styleMask.contains(.fullScreen)
        window.backgroundColor = NSColor(RoyalTheme.background)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
    }
    func close() { window?.performClose(nil) }
    func minimize() { window?.miniaturize(nil) }
    func zoom() { if fullScreen { window?.toggleFullScreen(nil) } else { window?.zoom(nil) } }
    func toggleFullScreen() { window?.toggleFullScreen(nil) }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// Dragging is limited to the title strip, never chat text or interactive controls.
struct RoyalDragSurface: NSViewRepresentable {
    let state: RoyalWindowState
    final class DragView: NSView {
        var state: RoyalWindowState?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { DispatchQueue.main.async { [weak self, weak window] in if let window { self?.state?.attach(window) } } } }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.zoom(nil)
                }
            } else { window.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> DragView { let view = DragView(); view.state = state; view.setAccessibilityElement(false); return view }
    func updateNSView(_ view: DragView, context: Context) { view.state = state }
}

struct RoyalGemControls: View {
    @Environment(\.royalPalette) private var palette
    @ObservedObject var state: RoyalWindowState
    var body: some View {
        let _ = palette
        HStack(spacing: 10) {
            gem("Close window", symbol: "xmark", color: Color(red: 0.85, green: 0.38, blue: 0.38), action: state.close)
            gem("Minimize window", symbol: "minus", color: Color(red: 0.92, green: 0.72, blue: 0.3), action: state.minimize).disabled(state.fullScreen)
            gem(state.fullScreen ? "Exit full screen" : "Maximize window", symbol: state.fullScreen ? "arrow.down.right.and.arrow.up.left" : "plus", color: Color(red: 0.39, green: 0.72, blue: 0.57), action: state.zoom)
                .contextMenu { Button(state.fullScreen ? "Exit Full Screen" : "Enter Full Screen", action: state.toggleFullScreen); Button("Zoom Window", action: state.zoom) }
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 15).fill(RoyalTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(LinearGradient(colors: [RoyalTheme.accentLight.opacity(0.9), RoyalTheme.accent.opacity(0.35), RoyalTheme.accent.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
        .overlay(alignment: .top) { Image(systemName: "crown.fill").font(.system(size: 9)).foregroundStyle(RoyalTheme.accent).offset(y: -6).accessibilityHidden(true) }
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .opacity(state.active ? 1 : 0.65)
    }
    func gem(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoyalGemShape().fill(LinearGradient(colors: [color.opacity(0.75), color, color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                RoyalGemShape().stroke(Color.white.opacity(0.35), lineWidth: 0.7)
                Image(systemName: symbol).font(.system(size: 8, weight: .heavy)).foregroundStyle(Color.black.opacity(0.75))
            }.frame(width: 17, height: 17).padding(3).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

/// Wraps only the main window. Standard app menus, sheets, focus, resizing and full screen survive.
struct RoyalWindowFrame<Content: View>: View {
    @Environment(\.royalPalette) private var palette
    @StateObject private var state = RoyalWindowState()
    @ViewBuilder var content: () -> Content
    var body: some View {
        let _ = palette
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                RoyalGemControls(state: state).padding(.leading, 15).padding(.trailing, 18)
                RoyalDragSurface(state: state)
                    .overlay(alignment: .leading) { HStack(spacing: 10) { RoyalMark(size: 23); Text("VORTEX").font(.system(size: 13, weight: .semibold)).tracking(3); Text("/  RED-XAI").font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(RoyalTheme.secondary); Spacer(); Text("YOUR PERSONAL AI WORKSPACE").font(.system(size: 9, weight: .medium)).tracking(1.8).foregroundStyle(RoyalTheme.secondary) }.padding(.trailing, 22).allowsHitTesting(false) }
            }.frame(height: 61).foregroundStyle(RoyalTheme.text).background(RoyalTheme.sidebar)
            Rectangle().fill(LinearGradient(colors: [RoyalTheme.accent.opacity(0.5), RoyalTheme.accent.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(RoyalTheme.background)
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: palette) { _, _ in state.update() }
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(RoyalTheme.accent.opacity(0.25), lineWidth: 1).allowsHitTesting(false) }
    }
}
