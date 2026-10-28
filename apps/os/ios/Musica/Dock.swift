// Musica: the floating dock (kits/ui/dock on iOS). A pill above the home indicator,
// icon + label; scrolling down folds it to icons only, scrolling up opens it again.
// The white bubble on the selected tab slides with a spring, and a drag across the
// pill scrubs it. The mini player floats with it: on top when open, beside it when folded.
import SwiftUI
import UIKit

enum Bar {
    /// Heights of the open dock (and mini player) and of the folded one.
    static let open: CGFloat = 60
    static let folded: CGFloat = 52
    static let gap: CGFloat = 8
}

/// Folded or open: every list reports its scroll here (ScrollSpy), the dock reads it.
@MainActor
final class DockState: ObservableObject {
    static let shared = DockState()
    @Published var compact = false
    private struct Watch { weak var sv: UIScrollView?; let obs: NSKeyValueObservation }
    private var watched: [ObjectIdentifier: Watch] = [:]
    private var last: [ObjectIdentifier: CGFloat] = [:]

    func watch(_ sv: UIScrollView) {
        let k = ObjectIdentifier(sv)
        // A new scroll view can reuse a dead one's address: compare the object, not the key.
        if let w = watched[k], w.sv === sv { return }
        let obs = sv.observe(\.contentOffset, options: [.new]) { sv, _ in
            Task { @MainActor in DockState.shared.moved(sv) }
        }
        watched[k] = Watch(sv: sv, obs: obs)
        last[k] = nil
    }

    private func moved(_ sv: UIScrollView) {
        let k = ObjectIdentifier(sv)
        let y = sv.contentOffset.y + sv.adjustedContentInset.top
        let prev = last[k] ?? y
        last[k] = y
        // Only the finger (and its fling) folds it: not a tab switch, not a programmatic jump.
        guard sv.isDragging || sv.isDecelerating else { return }
        if y < 24 { set(false); return }
        let d = y - prev
        if d > 5 { set(true) } else if d < -5 { set(false) }
    }

    func set(_ c: Bool) { if compact != c { compact = c } }
}

/// Invisible: finds the scroll view it lives in and hands it to the dock.
struct ScrollSpy: UIViewRepresentable {
    func makeUIView(context: Context) -> Spy {
        let v = Spy()
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ v: Spy, context: Context) {}

    final class Spy: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var v = superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            if let sv = v as? UIScrollView { DockState.shared.watch(sv) }
        }
    }
}

extension View {
    /// Put on a view inside a scroll (a LazyVStack, a List's first row): the dock folds with it.
    func dockScroll() -> some View { background(ScrollSpy().allowsHitTesting(false)) }
}

private struct BarInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// Height of the floating mini player + dock.
    var barInset: CGFloat {
        get { self[BarInsetKey.self] }
        set { self[BarInsetKey.self] = newValue }
    }
}

private struct UnderBar: ViewModifier {
    @Environment(\.barInset) private var h
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: h + 10) }
    }
}

extension View {
    /// A screen under the floating bar: its scroll ends above it.
    func underBar() -> some View { modifier(UnderBar()) }
}

/// Dark glass in a capsule, the surface of everything that floats.
struct Glass: View {
    var body: some View {
        Capsule(style: .continuous).fill(.ultraThinMaterial)
            .overlay(Capsule(style: .continuous).fill(Color.black.opacity(0.38)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }
}

/// Mini player + dock, floating over the screens.
struct BottomBar: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var dock: DockState
    @Binding var tab: String
    let reselect: (Pane) -> Void

    var body: some View {
        let c = dock.compact
        let layout = c ? AnyLayout(HStackLayout(alignment: .center, spacing: Bar.gap)) : AnyLayout(VStackLayout(spacing: Bar.gap))
        layout {
            if player.current != nil {
                MiniPlayer(compact: c)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Dock(tab: $tab, compact: c, reselect: reselect)
        }
        .padding(.horizontal, 14)
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: c)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: player.current == nil)
    }
}

/// The pill: three tabs, a white bubble under the chosen one.
struct Dock: View {
    @Binding var tab: String
    let compact: Bool
    let reselect: (Pane) -> Void
    @State private var hover: Int?
    private let panes = Pane.allCases

    var body: some View {
        let sel = panes.firstIndex { $0.rawValue == tab } ?? 0
        let shown = hover ?? sel
        let w: CGFloat = compact ? 50 : 76
        let h: CGFloat = (compact ? Bar.folded : Bar.open) - 8
        HStack(spacing: 0) {
            ForEach(Array(panes.enumerated()), id: \.offset) { i, p in
                let on = i == shown
                VStack(spacing: 2) {
                    Image(systemName: on ? p.iconOn : p.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 20)
                    if !compact {
                        Text(p.rawValue)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .top)))
                    }
                }
                .foregroundColor(on ? Brand.bg : Brand.dim)
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.rawValue)
                .accessibilityAddTraits(i == sel ? [.isButton, .isSelected] : [.isButton])
                .accessibilityAction { commit(i, sel) }
            }
        }
        .background(alignment: .leading) {
            Capsule(style: .continuous).fill(Brand.fg)
                .frame(width: w, height: h)
                .scaleEffect(hover != nil ? 1.07 : 1)
                .offset(x: CGFloat(shown) * w)
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let i = index(v.location.x, w)
                if hover != i {
                    if hover != nil || i != sel { Haptic.select() }
                    hover = i
                }
            }
            .onEnded { v in
                let i = index(v.location.x, w)
                hover = nil
                // Dragged far off the pill: let go without choosing.
                if v.location.y > -70 { commit(i, sel) }
            })
        .animation(hover != nil ? .interactiveSpring(response: 0.26, dampingFraction: 0.8) : .spring(response: 0.4, dampingFraction: 0.76), value: shown)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: hover != nil)
        .padding(4)
        .background(Glass())
    }

    private func index(_ x: CGFloat, _ w: CGFloat) -> Int {
        min(max(Int(x / w), 0), panes.count - 1)
    }

    private func commit(_ i: Int, _ sel: Int) {
        if i == sel {
            reselect(panes[i])
        } else {
            Haptic.tap()
            tab = panes[i].rawValue
        }
    }
}
