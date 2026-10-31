import MetalUI

/// The app's colour tokens (dark theme only), taken from the V1 dashboard mockup.
public enum Palette {
    /// Window ground.
    public static let ground = Color(Hsla.rgb(0x111316))
    /// Panels and cards.
    public static let panel = Color(Hsla.rgb(0x14161a))
    /// Top bar and other chrome.
    public static let chrome = Color(Hsla.rgb(0x0d0f12))
    /// Hairlines and borders.
    public static let line = Color(Hsla.rgb(0x23272e))
    /// Primary text.
    public static let text = Color(Hsla.rgb(0xe6e8eb))
    /// Body text in cards: between text and muted.
    public static let body = Color(Hsla.rgb(0xc9ced6))
    /// Secondary text.
    public static let muted = Color(Hsla.rgb(0x9aa1ab))
    /// Accent blue.
    public static let accent = Color(Hsla.rgb(0x5aa9ff))
    /// Needs-you amber.
    public static let warn = Color(Hsla.rgb(0xf0a35e))
    /// Success green.
    public static let ok = Color(Hsla.rgb(0x56d364))
    /// Failure red.
    public static let bad = Color(Hsla.rgb(0xff7b72))
}

/// Fonts: the system font for text, Menlo for code.
public enum Theme {
    /// Window and card titles.
    public static let title = Font.system(size: 15, weight: .semibold)
    /// Ordinary text.
    public static let body = Font.system(size: 13)
    /// Small secondary text.
    public static let caption = Font.system(size: 11)
    /// Code and logs, in Menlo, at `size` points.
    public static func mono(_ size: Double) -> Font { .custom("Menlo", size: size) }
}

/// Spacing scale in points.
public enum Spacing {
    /// 4
    public static let xs = Pixels(4)
    /// 8
    public static let sm = Pixels(8)
    /// 12
    public static let md = Pixels(12)
    /// 16
    public static let lg = Pixels(16)
}

/// The window the app opens at, and the smallest it may be resized to.
public let metalFlowWindowSize = Size(width: Pixels(1440), height: Pixels(900))
/// The smallest window size.
public let metalFlowMinimumSize = Size(width: Pixels(1000), height: Pixels(640))

/// Edge insets from plain numbers.
func insets(top: Double, right: Double, bottom: Double, left: Double) -> Edges<Pixels> {
    Edges(top: Pixels(floatLiteral: top), right: Pixels(floatLiteral: right), bottom: Pixels(floatLiteral: bottom), left: Pixels(floatLiteral: left))
}
