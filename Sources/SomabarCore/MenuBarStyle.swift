/// M13: a deliberately small set of menu bar styles. A tint (a solid colour or the system
/// accent), a 1 px hairline border, and separate values for light and dark mode. No gradients,
/// no custom shapes, no rounded floating bars. Off by default; Somabar has no brand colour.
public struct MenuBarStyle: Codable, Equatable, Sendable {
    public enum Tint: String, Codable, CaseIterable, Sendable {
        case none
        case accent
        case color
    }

    /// An sRGB colour, 0...1 per channel.
    public struct RGB: Codable, Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = Self.clamp(red)
            self.green = Self.clamp(green)
            self.blue = Self.clamp(blue)
        }

        public static let gray = RGB(red: 0.5, green: 0.5, blue: 0.5)

        static func clamp(_ value: Double) -> Double {
            value.isFinite ? min(1, max(0, value)) : 0
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                red: try c.decodeIfPresent(Double.self, forKey: .red) ?? 0.5,
                green: try c.decodeIfPresent(Double.self, forKey: .green) ?? 0.5,
                blue: try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0.5)
        }

        private enum CodingKeys: String, CodingKey {
            case red, green, blue
        }
    }

    /// The style for one appearance.
    public struct Appearance: Codable, Equatable, Sendable {
        public var tint: Tint = .none
        /// Used when `tint` is `.color`.
        public var color: RGB = .gray
        /// How strongly the tint shows, 0.1...1.
        public var strength: Double = 0.3
        public var hairline = false

        public init(tint: Tint = .none, color: RGB = .gray, strength: Double = 0.3, hairline: Bool = false) {
            self.tint = tint
            self.color = color
            self.strength = Self.clampStrength(strength)
            self.hairline = hairline
        }

        public static let strengthRange = 0.1...1.0

        static func clampStrength(_ value: Double) -> Double {
            value.isFinite ? min(strengthRange.upperBound, max(strengthRange.lowerBound, value)) : 0.3
        }

        /// Nothing to draw.
        public var isPlain: Bool { tint == .none && !hairline }

        private enum CodingKeys: String, CodingKey {
            case tint, color, strength, hairline
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // An unknown tint from a newer file reads as none rather than failing the document.
            let tint = (try? c.decodeIfPresent(Tint.self, forKey: .tint)) ?? Tint.none
            self.init(
                tint: tint,
                color: try c.decodeIfPresent(RGB.self, forKey: .color) ?? .gray,
                strength: try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0.3,
                hairline: try c.decodeIfPresent(Bool.self, forKey: .hairline) ?? false)
        }
    }

    public var light = Appearance()
    public var dark = Appearance()

    public init(light: Appearance = Appearance(), dark: Appearance = Appearance()) {
        self.light = light
        self.dark = dark
    }

    public func appearance(isDark: Bool) -> Appearance {
        isDark ? dark : light
    }

    /// Neither appearance draws anything, so no window is needed.
    public var isPlain: Bool { light.isPlain && dark.isPlain }

    private enum CodingKeys: String, CodingKey {
        case light, dark
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        light = try c.decodeIfPresent(Appearance.self, forKey: .light) ?? Appearance()
        dark = try c.decodeIfPresent(Appearance.self, forKey: .dark) ?? Appearance()
    }
}
