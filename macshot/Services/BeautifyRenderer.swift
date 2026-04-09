import Cocoa
import SwiftUI

enum BeautifyMode: Int {
    case window = 0   // macOS window chrome with traffic lights
    case rounded = 1  // just rounded corners, no title bar
}

/// Mesh gradient definition for macOS 15+ (3×3 grid of control points with colors)
struct MeshGradientDef {
    let width: Int   // always 3
    let height: Int  // always 3
    let points: [SIMD2<Float>]   // 9 points (row-major)
    let colors: [NSColor]        // 9 colors
}

struct BeautifyStyle {
    let name: String
    let stops: [(NSColor, CGFloat)]  // (color, location 0..1) — used for linear gradients & macOS 14 fallback
    let angle: CGFloat               // degrees, 0 = left→right, 90 = bottom→top
    let meshDef: MeshGradientDef?    // non-nil = mesh gradient (macOS 15+)

    /// Legacy convenience
    init(name: String, colors: (NSColor, NSColor)) {
        self.name = name
        self.stops = [(colors.0, 0), (colors.1, 1)]
        self.angle = 135  // top-left → bottom-right (matches old diagonal)
        self.meshDef = nil
    }

    init(name: String, stops: [(NSColor, CGFloat)], angle: CGFloat = 135) {
        self.name = name
        self.stops = stops
        self.angle = angle
        self.meshDef = nil
    }

    init(name: String, stops: [(NSColor, CGFloat)], angle: CGFloat = 135, mesh: MeshGradientDef) {
        self.name = name
        self.stops = stops
        self.angle = angle
        self.meshDef = mesh
    }

    var isMesh: Bool { meshDef != nil }
}

struct BeautifyConfig {
    var mode: BeautifyMode = .window
    var styleIndex: Int = 0
    var padding: CGFloat = 48       // 16..96
    var cornerRadius: CGFloat = 10  // 0..30
    var shadowRadius: CGFloat = 20  // 0..100
    var bgRadius: CGFloat = 8      // 0..30 (outer background corner radius)
    var isWindowSnap: Bool = false  // true = selection came from window snap, skip synthetic title bar
    var customBackgroundImage: NSImage?  // custom image background (nil = use gradient)
    var backgroundBlur: CGFloat = 0     // 0..50 blur radius for custom background

    /// Whether a custom background image is active
    var isCustomBackground: Bool { customBackgroundImage != nil }

    /// Convenience: the resolved style from styles array
    var style: BeautifyStyle {
        let count = BeautifyRenderer.styles.count
        let idx = ((styleIndex % count) + count) % count
        return BeautifyRenderer.styles[idx]
    }
}

class BeautifyRenderer {

    private static func meshStyle(name: String, points: [SIMD2<Float>], colors: [NSColor], fallbackStops: [(NSColor, CGFloat)], fallbackAngle: CGFloat = 135) -> BeautifyStyle {
        BeautifyStyle(
            name: name,
            stops: fallbackStops,
            angle: fallbackAngle,
            mesh: MeshGradientDef(width: 3, height: 3, points: points, colors: colors)
        )
    }

    static let styles: [BeautifyStyle] = {
        var s: [BeautifyStyle] = []

        // Mesh gradients — macOS 15+ only (18 = 3 rows of 6)
        // Bold colors, high contrast between neighbors, aggressive point displacement
        if #available(macOS 15.0, *) {
            let c = { (r: CGFloat, g: CGFloat, b: CGFloat) in NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }
            s.append(contentsOf: [
                // Row 1
                // Ultraviolet — vivid purple/magenta with electric blue
                meshStyle(name: "Ultraviolet", points: [
                    SIMD2(0, 0),    SIMD2(0.7, 0),   SIMD2(1, 0),
                    SIMD2(0, 0.3),  SIMD2(0.25, 0.7), SIMD2(1, 0.6),
                    SIMD2(0, 1),    SIMD2(0.65, 1),  SIMD2(1, 1),
                ], colors: [
                    c(0.55, 0.10, 0.95), c(0.80, 0.15, 0.80), c(1.0, 0.30, 0.55),
                    c(0.30, 0.15, 0.98), c(0.90, 0.40, 0.90), c(1.0, 0.50, 0.60),
                    c(0.15, 0.20, 0.95), c(0.50, 0.25, 0.95), c(0.85, 0.35, 0.70),
                ], fallbackStops: [
                    (c(0.55, 0.10, 0.95), 0), (c(0.90, 0.40, 0.90), 0.5), (c(0.85, 0.35, 0.70), 1),
                ]),
                // Inferno — hot pink/red smashing into orange/yellow
                meshStyle(name: "Inferno", points: [
                    SIMD2(0, 0),    SIMD2(0.3, 0),   SIMD2(1, 0),
                    SIMD2(0, 0.65), SIMD2(0.75, 0.35), SIMD2(1, 0.5),
                    SIMD2(0, 1),    SIMD2(0.4, 1),   SIMD2(1, 1),
                ], colors: [
                    c(1.0, 0.25, 0.40), c(1.0, 0.50, 0.20), c(1.0, 0.85, 0.25),
                    c(0.95, 0.15, 0.50), c(1.0, 0.65, 0.30), c(1.0, 0.90, 0.40),
                    c(0.85, 0.10, 0.35), c(1.0, 0.40, 0.25), c(1.0, 0.75, 0.20),
                ], fallbackStops: [
                    (c(1.0, 0.25, 0.40), 0), (c(1.0, 0.65, 0.30), 0.5), (c(1.0, 0.85, 0.25), 1),
                ]),
                // Deep Ocean — rich blue/teal with bright cyan burst
                meshStyle(name: "Deep Ocean", points: [
                    SIMD2(0, 0),    SIMD2(0.6, 0),   SIMD2(1, 0),
                    SIMD2(0, 0.4),  SIMD2(0.3, 0.65), SIMD2(1, 0.55),
                    SIMD2(0, 1),    SIMD2(0.7, 1),   SIMD2(1, 1),
                ], colors: [
                    c(0.05, 0.15, 0.60), c(0.10, 0.40, 0.90), c(0.05, 0.20, 0.70),
                    c(0.08, 0.25, 0.75), c(0.20, 0.90, 0.95), c(0.10, 0.50, 0.85),
                    c(0.03, 0.10, 0.45), c(0.08, 0.35, 0.80), c(0.05, 0.18, 0.55),
                ], fallbackStops: [
                    (c(0.05, 0.15, 0.60), 0), (c(0.20, 0.90, 0.95), 0.5), (c(0.05, 0.18, 0.55), 1),
                ]),
                // Candy Floss — saturated pink/peach/lavender
                meshStyle(name: "Candy Floss", points: [
                    SIMD2(0, 0),    SIMD2(0.45, 0),  SIMD2(1, 0),
                    SIMD2(0, 0.6),  SIMD2(0.7, 0.4),  SIMD2(1, 0.55),
                    SIMD2(0, 1),    SIMD2(0.35, 1),  SIMD2(1, 1),
                ], colors: [
                    c(1.0, 0.60, 0.70), c(1.0, 0.75, 0.55), c(0.95, 0.55, 0.75),
                    c(0.95, 0.50, 0.80), c(1.0, 0.85, 0.70), c(0.80, 0.55, 0.95),
                    c(0.85, 0.45, 0.90), c(0.95, 0.70, 0.80), c(0.70, 0.50, 0.98),
                ], fallbackStops: [
                    (c(1.0, 0.60, 0.70), 0), (c(1.0, 0.85, 0.70), 0.5), (c(0.70, 0.50, 0.98), 1),
                ]),
                // Emerald Fire — vivid green clashing with hot orange
                meshStyle(name: "Emerald Fire", points: [
                    SIMD2(0, 0),    SIMD2(0.55, 0),  SIMD2(1, 0),
                    SIMD2(0, 0.5),  SIMD2(0.25, 0.55), SIMD2(1, 0.4),
                    SIMD2(0, 1),    SIMD2(0.6, 1),   SIMD2(1, 1),
                ], colors: [
                    c(0.10, 0.85, 0.40), c(0.30, 0.95, 0.50), c(0.90, 0.75, 0.15),
                    c(0.05, 0.70, 0.35), c(0.60, 0.90, 0.30), c(1.0, 0.60, 0.15),
                    c(0.08, 0.55, 0.30), c(0.40, 0.80, 0.25), c(1.0, 0.45, 0.10),
                ], fallbackStops: [
                    (c(0.10, 0.85, 0.40), 0), (c(0.60, 0.90, 0.30), 0.5), (c(1.0, 0.45, 0.10), 1),
                ]),
                // Electric Dusk — neon pink/orange sunset over deep blue
                meshStyle(name: "Electric Dusk", points: [
                    SIMD2(0, 0),    SIMD2(0.5, 0),   SIMD2(1, 0),
                    SIMD2(0, 0.35), SIMD2(0.65, 0.55), SIMD2(1, 0.4),
                    SIMD2(0, 1),    SIMD2(0.45, 1),  SIMD2(1, 1),
                ], colors: [
                    c(1.0, 0.50, 0.30), c(1.0, 0.35, 0.50), c(0.90, 0.25, 0.70),
                    c(1.0, 0.65, 0.20), c(0.85, 0.30, 0.60), c(0.45, 0.15, 0.80),
                    c(0.15, 0.10, 0.50), c(0.10, 0.12, 0.55), c(0.08, 0.08, 0.40),
                ], fallbackStops: [
                    (c(1.0, 0.50, 0.30), 0), (c(0.85, 0.30, 0.60), 0.5), (c(0.08, 0.08, 0.40), 1),
                ], fallbackAngle: 180),

                // Row 2
                // Plasma — magenta/cyan/yellow high-energy
                meshStyle(name: "Plasma", points: [
                    SIMD2(0, 0),    SIMD2(0.25, 0),  SIMD2(1, 0),
                    SIMD2(0, 0.7),  SIMD2(0.8, 0.3),  SIMD2(1, 0.5),
                    SIMD2(0, 1),    SIMD2(0.55, 1),  SIMD2(1, 1),
                ], colors: [
                    c(0.95, 0.20, 0.60), c(1.0, 0.50, 0.15), c(1.0, 0.90, 0.20),
                    c(0.70, 0.10, 0.90), c(0.20, 0.85, 0.85), c(0.50, 0.95, 0.40),
                    c(0.25, 0.15, 0.95), c(0.15, 0.60, 0.95), c(0.10, 0.90, 0.70),
                ], fallbackStops: [
                    (c(0.95, 0.20, 0.60), 0), (c(0.20, 0.85, 0.85), 0.5), (c(0.25, 0.15, 0.95), 1),
                ]),
                // Silk Storm — whites/grays with vivid color pockets
                meshStyle(name: "Silk Storm", points: [
                    SIMD2(0, 0),    SIMD2(0.65, 0),  SIMD2(1, 0),
                    SIMD2(0, 0.45), SIMD2(0.3, 0.6),  SIMD2(1, 0.55),
                    SIMD2(0, 1),    SIMD2(0.5, 1),   SIMD2(1, 1),
                ], colors: [
                    c(0.92, 0.90, 0.95), c(0.70, 0.80, 0.98), c(0.55, 0.60, 0.98),
                    c(0.95, 0.85, 0.88), c(0.85, 0.75, 0.95), c(0.50, 0.70, 0.95),
                    c(0.98, 0.92, 0.88), c(0.90, 0.82, 0.90), c(0.65, 0.75, 0.95),
                ], fallbackStops: [
                    (c(0.92, 0.90, 0.95), 0), (c(0.85, 0.75, 0.95), 0.5), (c(0.65, 0.75, 0.95), 1),
                ]),
                // Opal — orange/teal/violet iridescent clash
                meshStyle(name: "Opal", points: [
                    SIMD2(0, 0),    SIMD2(0.7, 0),   SIMD2(1, 0),
                    SIMD2(0, 0.4),  SIMD2(0.25, 0.65), SIMD2(1, 0.5),
                    SIMD2(0, 1),    SIMD2(0.6, 1),   SIMD2(1, 1),
                ], colors: [
                    c(1.0, 0.60, 0.15), c(1.0, 0.85, 0.30), c(0.20, 0.90, 0.90),
                    c(0.95, 0.40, 0.40), c(0.65, 0.70, 0.95), c(0.15, 0.75, 0.95),
                    c(0.60, 0.15, 0.85), c(0.40, 0.35, 0.95), c(0.20, 0.55, 0.95),
                ], fallbackStops: [
                    (c(1.0, 0.60, 0.15), 0), (c(0.65, 0.70, 0.95), 0.5), (c(0.60, 0.15, 0.85), 1),
                ]),
                // Nebula — deep purple/blue with hot pink explosion
                meshStyle(name: "Nebula", points: [
                    SIMD2(0, 0),    SIMD2(0.55, 0),  SIMD2(1, 0),
                    SIMD2(0, 0.55), SIMD2(0.3, 0.4),  SIMD2(1, 0.65),
                    SIMD2(0, 1),    SIMD2(0.7, 1),   SIMD2(1, 1),
                ], colors: [
                    c(0.10, 0.05, 0.40), c(0.30, 0.08, 0.60), c(0.08, 0.15, 0.55),
                    c(0.50, 0.10, 0.65), c(1.0, 0.30, 0.55), c(0.15, 0.30, 0.80),
                    c(0.65, 0.15, 0.50), c(0.35, 0.20, 0.70), c(0.10, 0.40, 0.75),
                ], fallbackStops: [
                    (c(0.10, 0.05, 0.40), 0), (c(1.0, 0.30, 0.55), 0.5), (c(0.10, 0.40, 0.75), 1),
                ]),
                // Sunset Blaze — intense orange/red to deep indigo
                meshStyle(name: "Sunset Blaze", points: [
                    SIMD2(0, 0),    SIMD2(0.5, 0),   SIMD2(1, 0),
                    SIMD2(0, 0.35), SIMD2(0.4, 0.55), SIMD2(1, 0.4),
                    SIMD2(0, 1),    SIMD2(0.6, 1),   SIMD2(1, 1),
                ], colors: [
                    c(1.0, 0.85, 0.25), c(1.0, 0.55, 0.15), c(1.0, 0.30, 0.25),
                    c(1.0, 0.50, 0.10), c(0.90, 0.25, 0.40), c(0.55, 0.12, 0.60),
                    c(0.12, 0.08, 0.35), c(0.10, 0.06, 0.45), c(0.08, 0.05, 0.35),
                ], fallbackStops: [
                    (c(1.0, 0.85, 0.25), 0), (c(0.90, 0.25, 0.40), 0.5), (c(0.08, 0.05, 0.35), 1),
                ], fallbackAngle: 180),
                // Lagoon — vivid teal/cyan/deep blue tropical
                meshStyle(name: "Lagoon", points: [
                    SIMD2(0, 0),    SIMD2(0.4, 0),   SIMD2(1, 0),
                    SIMD2(0, 0.5),  SIMD2(0.7, 0.6),  SIMD2(1, 0.45),
                    SIMD2(0, 1),    SIMD2(0.35, 1),  SIMD2(1, 1),
                ], colors: [
                    c(0.10, 0.95, 0.70), c(0.20, 0.95, 0.90), c(0.15, 0.65, 0.98),
                    c(0.05, 0.80, 0.55), c(0.15, 0.90, 0.85), c(0.25, 0.50, 0.95),
                    c(0.03, 0.55, 0.40), c(0.08, 0.70, 0.65), c(0.10, 0.35, 0.85),
                ], fallbackStops: [
                    (c(0.10, 0.95, 0.70), 0), (c(0.15, 0.90, 0.85), 0.5), (c(0.10, 0.35, 0.85), 1),
                ]),

                // Row 3 — maximum drama
                // Molten Core — black with searing orange/white-hot center
                meshStyle(name: "Molten Core", points: [
                    SIMD2(0, 0),    SIMD2(0.6, 0),   SIMD2(1, 0),
                    SIMD2(0, 0.5),  SIMD2(0.35, 0.45), SIMD2(1, 0.6),
                    SIMD2(0, 1),    SIMD2(0.5, 1),   SIMD2(1, 1),
                ], colors: [
                    c(0.08, 0.05, 0.05), c(0.20, 0.05, 0.02), c(0.10, 0.03, 0.05),
                    c(0.30, 0.08, 0.02), c(1.0, 0.70, 0.15), c(0.45, 0.10, 0.03),
                    c(0.05, 0.03, 0.03), c(0.85, 0.35, 0.05), c(0.08, 0.04, 0.04),
                ], fallbackStops: [
                    (c(0.08, 0.05, 0.05), 0), (c(1.0, 0.70, 0.15), 0.5), (c(0.08, 0.04, 0.04), 1),
                ]),
                // Aurora Borealis — green/cyan curtains over dark sky
                meshStyle(name: "Aurora Borealis", points: [
                    SIMD2(0, 0),    SIMD2(0.35, 0),  SIMD2(1, 0),
                    SIMD2(0, 0.6),  SIMD2(0.75, 0.35), SIMD2(1, 0.55),
                    SIMD2(0, 1),    SIMD2(0.45, 1),  SIMD2(1, 1),
                ], colors: [
                    c(0.05, 0.90, 0.50), c(0.10, 0.95, 0.80), c(0.20, 0.70, 0.95),
                    c(0.08, 0.70, 0.40), c(0.15, 0.85, 0.70), c(0.30, 0.50, 0.90),
                    c(0.03, 0.08, 0.18), c(0.05, 0.10, 0.25), c(0.04, 0.06, 0.20),
                ], fallbackStops: [
                    (c(0.05, 0.90, 0.50), 0), (c(0.15, 0.85, 0.70), 0.5), (c(0.04, 0.06, 0.20), 1),
                ], fallbackAngle: 180),
                // Prism Burst — rainbow refraction: every color at full saturation
                meshStyle(name: "Prism Burst", points: [
                    SIMD2(0, 0),    SIMD2(0.3, 0),   SIMD2(1, 0),
                    SIMD2(0, 0.55), SIMD2(0.7, 0.5),  SIMD2(1, 0.45),
                    SIMD2(0, 1),    SIMD2(0.4, 1),   SIMD2(1, 1),
                ], colors: [
                    c(0.20, 0.40, 1.0),  c(1.0, 0.60, 0.10), c(1.0, 0.25, 0.50),
                    c(0.10, 0.85, 0.70), c(1.0, 0.95, 0.50), c(0.90, 0.20, 0.80),
                    c(0.15, 0.90, 0.35), c(0.95, 0.80, 0.15), c(0.60, 0.10, 0.95),
                ], fallbackStops: [
                    (c(0.20, 0.40, 1.0), 0), (c(1.0, 0.95, 0.50), 0.5), (c(0.60, 0.10, 0.95), 1),
                ]),
                // Velvet Night — dark burgundy/plum with rose-gold glow
                meshStyle(name: "Velvet Night", points: [
                    SIMD2(0, 0),    SIMD2(0.55, 0),  SIMD2(1, 0),
                    SIMD2(0, 0.55), SIMD2(0.3, 0.4),  SIMD2(1, 0.5),
                    SIMD2(0, 1),    SIMD2(0.65, 1),  SIMD2(1, 1),
                ], colors: [
                    c(0.25, 0.05, 0.15), c(0.40, 0.08, 0.20), c(0.30, 0.06, 0.25),
                    c(0.35, 0.10, 0.18), c(0.95, 0.65, 0.50), c(0.45, 0.12, 0.35),
                    c(0.20, 0.05, 0.15), c(0.60, 0.30, 0.30), c(0.25, 0.08, 0.22),
                ], fallbackStops: [
                    (c(0.25, 0.05, 0.15), 0), (c(0.95, 0.65, 0.50), 0.5), (c(0.25, 0.08, 0.22), 1),
                ]),
                // Cosmic Reef — deep space with teal/coral/gold nebula clouds
                meshStyle(name: "Cosmic Reef", points: [
                    SIMD2(0, 0),    SIMD2(0.65, 0),  SIMD2(1, 0),
                    SIMD2(0, 0.4),  SIMD2(0.25, 0.65), SIMD2(1, 0.55),
                    SIMD2(0, 1),    SIMD2(0.55, 1),  SIMD2(1, 1),
                ], colors: [
                    c(0.06, 0.04, 0.20), c(0.15, 0.60, 0.70), c(0.08, 0.08, 0.30),
                    c(0.90, 0.45, 0.30), c(0.10, 0.10, 0.25), c(0.20, 0.50, 0.80),
                    c(1.0, 0.80, 0.25),  c(0.06, 0.06, 0.22), c(0.12, 0.35, 0.65),
                ], fallbackStops: [
                    (c(0.06, 0.04, 0.20), 0), (c(0.90, 0.45, 0.30), 0.4), (c(1.0, 0.80, 0.25), 1),
                ]),
                // Ember Glow — searing warm gradient: gold/coral/crimson
                meshStyle(name: "Ember Glow", points: [
                    SIMD2(0, 0),    SIMD2(0.45, 0),  SIMD2(1, 0),
                    SIMD2(0, 0.6),  SIMD2(0.7, 0.4),  SIMD2(1, 0.5),
                    SIMD2(0, 1),    SIMD2(0.35, 1),  SIMD2(1, 1),
                ], colors: [
                    c(1.0, 0.85, 0.35), c(1.0, 0.65, 0.25), c(1.0, 0.50, 0.30),
                    c(1.0, 0.55, 0.20), c(0.95, 0.40, 0.35), c(0.90, 0.30, 0.45),
                    c(0.80, 0.20, 0.25), c(0.90, 0.30, 0.30), c(0.75, 0.15, 0.40),
                ], fallbackStops: [
                    (c(1.0, 0.85, 0.35), 0), (c(0.95, 0.40, 0.35), 0.5), (c(0.75, 0.15, 0.40), 1),
                ]),
            ])
        }

        // Linear gradients
        s.append(contentsOf: [
            // Warm / sunset / orange
            BeautifyStyle(name: "Sunset", stops: [
                (NSColor(calibratedRed: 1.00, green: 0.60, blue: 0.15, alpha: 1), 0),
                (NSColor(calibratedRed: 0.98, green: 0.35, blue: 0.30, alpha: 1), 0.45),
                (NSColor(calibratedRed: 0.85, green: 0.18, blue: 0.45, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Peach", stops: [
                (NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.68, alpha: 1), 0),
                (NSColor(calibratedRed: 0.95, green: 0.60, blue: 0.55, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Ember", stops: [
                (NSColor(calibratedRed: 0.90, green: 0.25, blue: 0.10, alpha: 1), 0),
                (NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.05, alpha: 1), 0.5),
                (NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.20, alpha: 1), 1),
            ], angle: 135),

            // Blues / cool
            BeautifyStyle(name: "Ocean", stops: [
                (NSColor(calibratedRed: 0.10, green: 0.70, blue: 0.95, alpha: 1), 0),
                (NSColor(calibratedRed: 0.22, green: 0.40, blue: 0.90, alpha: 1), 0.55),
                (NSColor(calibratedRed: 0.35, green: 0.20, blue: 0.80, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Sky", stops: [
                (NSColor(calibratedRed: 0.72, green: 0.90, blue: 0.98, alpha: 1), 0),
                (NSColor(calibratedRed: 0.50, green: 0.75, blue: 0.95, alpha: 1), 1),
            ], angle: 160),
            BeautifyStyle(name: "Cobalt", stops: [
                (NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.55, alpha: 1), 0),
                (NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.85, alpha: 1), 0.5),
                (NSColor(calibratedRed: 0.30, green: 0.60, blue: 0.95, alpha: 1), 1),
            ], angle: 150),

            // Pink / purple / vibrant
            BeautifyStyle(name: "Candy", stops: [
                (NSColor(calibratedRed: 0.98, green: 0.40, blue: 0.55, alpha: 1), 0),
                (NSColor(calibratedRed: 0.90, green: 0.30, blue: 0.70, alpha: 1), 0.4),
                (NSColor(calibratedRed: 0.60, green: 0.25, blue: 0.90, alpha: 1), 0.75),
                (NSColor(calibratedRed: 0.35, green: 0.30, blue: 0.95, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Love", stops: [
                (NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.45, alpha: 1), 0),
                (NSColor(calibratedRed: 0.92, green: 0.50, blue: 0.55, alpha: 1), 1),
            ], angle: 150),
            BeautifyStyle(name: "Lavender", stops: [
                (NSColor(calibratedRed: 0.75, green: 0.65, blue: 0.95, alpha: 1), 0),
                (NSColor(calibratedRed: 0.90, green: 0.78, blue: 0.98, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Neon", stops: [
                (NSColor(calibratedRed: 0.98, green: 0.20, blue: 0.60, alpha: 1), 0),
                (NSColor(calibratedRed: 0.90, green: 0.50, blue: 0.15, alpha: 1), 0.3),
                (NSColor(calibratedRed: 0.20, green: 0.90, blue: 0.60, alpha: 1), 0.6),
                (NSColor(calibratedRed: 0.25, green: 0.50, blue: 0.98, alpha: 1), 1),
            ], angle: 135),

            // Greens / nature
            BeautifyStyle(name: "Forest", stops: [
                (NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.30, alpha: 1), 0),
                (NSColor(calibratedRed: 0.10, green: 0.60, blue: 0.40, alpha: 1), 0.5),
                (NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.50, alpha: 1), 1),
            ], angle: 150),
            BeautifyStyle(name: "Aurora", stops: [
                (NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.50, alpha: 1), 0),
                (NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.80, alpha: 1), 0.35),
                (NSColor(calibratedRed: 0.40, green: 0.30, blue: 0.85, alpha: 1), 0.65),
                (NSColor(calibratedRed: 0.70, green: 0.25, blue: 0.75, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Lime", stops: [
                (NSColor(calibratedRed: 0.55, green: 0.90, blue: 0.20, alpha: 1), 0),
                (NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.35, alpha: 1), 0.5),
                (NSColor(calibratedRed: 0.15, green: 0.60, blue: 0.45, alpha: 1), 1),
            ], angle: 135),

            // Multicolor / dreamy
            BeautifyStyle(name: "Dreamy", stops: [
                (NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.98, alpha: 1), 0),
                (NSColor(calibratedRed: 0.75, green: 0.60, blue: 0.95, alpha: 1), 0.35),
                (NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.70, alpha: 1), 0.7),
                (NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.40, alpha: 1), 1),
            ], angle: 150),
            BeautifyStyle(name: "Rainbow", stops: [
                (NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.30, alpha: 1), 0),
                (NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.20, alpha: 1), 0.25),
                (NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.40, alpha: 1), 0.5),
                (NSColor(calibratedRed: 0.30, green: 0.60, blue: 0.95, alpha: 1), 0.75),
                (NSColor(calibratedRed: 0.70, green: 0.30, blue: 0.90, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Twilight", stops: [
                (NSColor(calibratedRed: 0.15, green: 0.10, blue: 0.35, alpha: 1), 0),
                (NSColor(calibratedRed: 0.45, green: 0.20, blue: 0.60, alpha: 1), 0.4),
                (NSColor(calibratedRed: 0.85, green: 0.40, blue: 0.50, alpha: 1), 0.7),
                (NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.40, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Hologram", stops: [
                (NSColor(calibratedRed: 0.40, green: 0.90, blue: 0.85, alpha: 1), 0),
                (NSColor(calibratedRed: 0.50, green: 0.65, blue: 0.98, alpha: 1), 0.35),
                (NSColor(calibratedRed: 0.80, green: 0.50, blue: 0.95, alpha: 1), 0.65),
                (NSColor(calibratedRed: 0.95, green: 0.60, blue: 0.80, alpha: 1), 1),
            ], angle: 120),

            // Dark / moody
            BeautifyStyle(name: "Midnight", stops: [
                (NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.15, alpha: 1), 0),
                (NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.30, alpha: 1), 0.5),
                (NSColor(calibratedRed: 0.20, green: 0.15, blue: 0.45, alpha: 1), 1),
            ], angle: 150),
            BeautifyStyle(name: "Abyss", stops: [
                (NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.12, alpha: 1), 0),
                (NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.30, alpha: 1), 0.4),
                (NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.50, alpha: 1), 0.75),
                (NSColor(calibratedRed: 0.15, green: 0.50, blue: 0.55, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Noir", stops: [
                (NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.03, alpha: 1), 0),
                (NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1), 1),
            ], angle: 135),

            // Clean / neutral / light
            BeautifyStyle(name: "Snow", stops: [
                (NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1), 0),
                (NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.93, alpha: 1), 1),
            ], angle: 160),
            BeautifyStyle(name: "Cream", stops: [
                (NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.90, alpha: 1), 0),
                (NSColor(calibratedRed: 0.95, green: 0.90, blue: 0.80, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Slate", stops: [
                (NSColor(calibratedRed: 0.30, green: 0.35, blue: 0.42, alpha: 1), 0),
                (NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.58, alpha: 1), 0.5),
                (NSColor(calibratedRed: 0.60, green: 0.65, blue: 0.72, alpha: 1), 1),
            ], angle: 135),
            BeautifyStyle(name: "Charcoal", stops: [
                (NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.18, alpha: 1), 0),
                (NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.30, alpha: 1), 0.5),
                (NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.40, alpha: 1), 1),
            ], angle: 150),
        ])

        // Extra non-mesh gradients
        let c = { (r: CGFloat, g: CGFloat, b: CGFloat) in NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }
        s.append(contentsOf: [
            BeautifyStyle(name: "Emerald", stops: [(c(0.0, 0.6, 0.4), 0), (c(0.1, 0.85, 0.6), 0.5), (c(0.0, 0.5, 0.3), 1)], angle: 135),
            BeautifyStyle(name: "Cherry", stops: [(c(0.7, 0.1, 0.2), 0), (c(0.9, 0.2, 0.3), 0.5), (c(0.55, 0.05, 0.15), 1)], angle: 150),
            BeautifyStyle(name: "Sapphire", stops: [(c(0.1, 0.15, 0.5), 0), (c(0.2, 0.3, 0.75), 0.5), (c(0.05, 0.1, 0.4), 1)], angle: 120),
            BeautifyStyle(name: "Sand", stops: [(c(0.85, 0.75, 0.55), 0), (c(0.95, 0.88, 0.7), 0.5), (c(0.75, 0.65, 0.45), 1)], angle: 135),
            BeautifyStyle(name: "Pure White", stops: [(c(0.95, 0.95, 0.95), 0), (c(1.0, 1.0, 1.0), 0.5), (c(0.92, 0.92, 0.92), 1)], angle: 180),
            BeautifyStyle(name: "Pure Black", stops: [(c(0.05, 0.05, 0.05), 0), (c(0.12, 0.12, 0.12), 0.5), (c(0.0, 0.0, 0.0), 1)], angle: 180),
        ])

        return s
    }()

    // MARK: - Legacy API (keeps existing callers working)

    static func render(image: NSImage, styleIndex: Int) -> NSImage {
        let config = BeautifyConfig(mode: .window, styleIndex: styleIndex)
        return render(image: image, config: config)
    }

    // MARK: - New configurable API

    static func render(image: NSImage, config: BeautifyConfig) -> NSImage {
        // Snapped windows always use the dedicated renderer (no synthetic chrome needed)
        if config.isWindowSnap {
            return renderSnappedWindow(image: image, config: config)
        }
        switch config.mode {
        case .window:
            return renderWindow(image: image, config: config)
        case .rounded:
            return renderRounded(image: image, config: config)
        }
    }

    /// Pre-render the mesh gradient for a given size (call before entering NSImage drawing handlers
    /// to avoid calling @MainActor-isolated SwiftUI ImageRenderer from a non-isolated closure).
    static func prerenderBackground(config: BeautifyConfig, width: Int, height: Int) -> CGImage? {
        if config.isCustomBackground { return nil }
        let style = config.style
        if #available(macOS 15.0, *), let mesh = style.meshDef {
            return renderMeshGradient(mesh, width: width, height: height)
        }
        return nil
    }

    /// Draw just the background gradient (or custom image) into a rect (for live overlay preview).
    /// Pass `prerenderedMesh` from `prerenderBackground()` when calling from inside an NSImage drawing handler.
    static func drawGradientBackground(in rect: NSRect, config: BeautifyConfig, context: CGContext, prerenderedMesh: CGImage? = nil) {
        // Custom image background
        if let bgImage = config.customBackgroundImage {
            var imageToDraw = bgImage
            // Apply blur if configured
            if config.backgroundBlur > 0, let cgImg = bgImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let ciImage = CIImage(cgImage: cgImg)
                if let filter = CIFilter(name: "CIGaussianBlur") {
                    filter.setValue(ciImage, forKey: kCIInputImageKey)
                    filter.setValue(config.backgroundBlur, forKey: kCIInputRadiusKey)
                    let ciCtx = CIContext()
                    if let output = filter.outputImage,
                       let blurredCG = ciCtx.createCGImage(output, from: ciImage.extent) {
                        imageToDraw = NSImage(cgImage: blurredCG, size: bgImage.size)
                    }
                }
            }
            // Draw image scaled to fill the rect (aspect fill + center crop)
            let imgSize = imageToDraw.size
            let scaleX = rect.width / imgSize.width
            let scaleY = rect.height / imgSize.height
            let fillScale = max(scaleX, scaleY)
            let drawW = imgSize.width * fillScale
            let drawH = imgSize.height * fillScale
            let drawRect = NSRect(
                x: rect.minX + (rect.width - drawW) / 2,
                y: rect.minY + (rect.height - drawH) / 2,
                width: drawW, height: drawH)
            context.saveGState()
            context.clip(to: rect)
            imageToDraw.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
            context.restoreGState()
            return
        }

        // Use pre-rendered mesh gradient if provided
        if let meshImage = prerenderedMesh {
            context.draw(meshImage, in: rect)
            return
        }

        let style = config.style

        // Mesh gradient path (macOS 15+) — only reached from callers that don't pre-render (e.g. overlay preview)
        if #available(macOS 15.0, *), let mesh = style.meshDef {
            if let cgImage = renderMeshGradient(mesh, width: Int(rect.width), height: Int(rect.height)) {
                context.draw(cgImage, in: rect)
                return
            }
        }

        // Linear gradient fallback
        let colors = style.stops.map { $0.0.cgColor } as CFArray
        var locations = style.stops.map { $0.1 }
        let cs = CGColorSpaceCreateDeviceRGB()

        guard let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: &locations) else { return }

        // Convert angle (degrees) to start/end points within the rect
        let radians = style.angle * .pi / 180
        let dx = cos(radians)
        let dy = sin(radians)
        let cx = rect.midX
        let cy = rect.midY
        // Project to rect edges
        let halfW = rect.width / 2
        let halfH = rect.height / 2
        let scale = max(abs(dx) > 0.001 ? halfW / abs(dx) : .greatestFiniteMagnitude,
                        abs(dy) > 0.001 ? halfH / abs(dy) : .greatestFiniteMagnitude)
        let len = min(scale, hypot(halfW, halfH))
        let start = CGPoint(x: cx - dx * len, y: cy - dy * len)
        let end = CGPoint(x: cx + dx * len, y: cy + dy * len)

        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Render a SwiftUI MeshGradient offscreen into a CGImage (macOS 15+).
    /// Must be called from the main thread (uses SwiftUI ImageRenderer).
    @available(macOS 15.0, *)
    static func renderMeshGradient(_ mesh: MeshGradientDef, width: Int, height: Int) -> CGImage? {
        let w = max(width, 1)
        let h = max(height, 1)

        let swiftUIColors = mesh.colors.map { Color(nsColor: $0) }
        let view = MeshGradient(
            width: mesh.width,
            height: mesh.height,
            points: mesh.points,
            colors: swiftUIColors
        )
        .frame(width: CGFloat(w), height: CGFloat(h))

        return MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1.0
            return renderer.cgImage
        }
    }

    /// Render a mesh gradient swatch for the picker (cached-friendly small size)
    @available(macOS 15.0, *)
    static func renderMeshSwatch(_ mesh: MeshGradientDef, size: CGFloat) -> NSImage? {
        guard let cgImage = renderMeshGradient(mesh, width: Int(size * 2), height: Int(size * 2)) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    // MARK: - Window mode (macOS title bar chrome)

    private static func renderWindow(image: NSImage, config: BeautifyConfig) -> NSImage {
        let style = config.style
        let imgSize = image.size
        let padding = config.padding
        let windowCornerRadius = config.cornerRadius
        let shadowRadius = config.shadowRadius
        let shadowOffset = min(shadowRadius * 0.3, 8)
        let titleBarHeight: CGFloat = 28

        let windowWidth = imgSize.width
        let windowHeight = imgSize.height + titleBarHeight

        let totalWidth = windowWidth + padding * 2
        let totalHeight = windowHeight + padding * 2

        // Pre-render mesh gradient outside the drawing handler to avoid @MainActor isolation issues
        let prerenderedMesh = prerenderBackground(config: config, width: Int(totalWidth), height: Int(totalHeight))

        var success = false
        let result = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return true
            }

            // Gradient background — fill entire canvas, no outer rounding
            let bgRect = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
            context.saveGState()
            drawGradientBackground(in: bgRect, config: config, context: context, prerenderedMesh: prerenderedMesh)
            context.restoreGState()

            // Window frame position
            let windowX = padding
            let windowY = padding

            // Drop shadow
            if shadowRadius > 0 {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = shadowRadius
                shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                let windowRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
                NSBezierPath(roundedRect: windowRect, xRadius: windowCornerRadius, yRadius: windowCornerRadius).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // Draw window background clipped
            let windowRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
            context.saveGState()
            let clipPath = NSBezierPath(roundedRect: windowRect, xRadius: windowCornerRadius, yRadius: windowCornerRadius)
            clipPath.addClip()

            NSColor(white: 0.97, alpha: 1.0).setFill()
            NSBezierPath(rect: windowRect).fill()

            // Title bar
            let titleBarRect = NSRect(x: windowX, y: windowY + windowHeight - titleBarHeight, width: windowWidth, height: titleBarHeight)
            NSColor(white: 0.94, alpha: 1.0).setFill()
            NSBezierPath(rect: titleBarRect).fill()

            // Separator
            NSColor(white: 0.82, alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(x: windowX, y: titleBarRect.minY - 0.5, width: windowWidth, height: 0.5)).fill()

            // Traffic lights
            let buttonY = titleBarRect.midY
            let buttonRadius: CGFloat = 6
            let buttonStartX = windowX + 14
            let buttonSpacing: CGFloat = 20

            let trafficLights: [(NSColor, NSColor)] = [
                (NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
                 NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.22, alpha: 1.0)),
                (NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.25, alpha: 1.0),
                 NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.15, alpha: 1.0)),
                (NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 1.0),
                 NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.25, alpha: 1.0)),
            ]

            for (i, (fill, ring)) in trafficLights.enumerated() {
                let cx = buttonStartX + CGFloat(i) * buttonSpacing
                let circleRect = NSRect(x: cx - buttonRadius, y: buttonY - buttonRadius, width: buttonRadius * 2, height: buttonRadius * 2)
                fill.setFill()
                NSBezierPath(ovalIn: circleRect).fill()
                ring.setStroke()
                let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 0.5
                border.stroke()
            }

            // Screenshot image
            let contentRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight - titleBarHeight)
            image.draw(in: contentRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            context.restoreGState()

            success = true
            return true
        }
        if !success {
            // Force the drawing handler to run so we can check `success`
            _ = result.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return success ? result : image
    }

    // MARK: - Snapped window mode (native window chrome, no synthetic title bar)

    /// Renders a snapped window: the image already contains the native window chrome
    /// (title bar, traffic lights, rounded corners). We just place it on the gradient
    /// background with a drop shadow — no synthetic elements needed.
    private static func renderSnappedWindow(image: NSImage, config: BeautifyConfig) -> NSImage {
        let imgSize = image.size
        let padding = config.padding
        let shadowRadius = config.shadowRadius
        let shadowOffset = min(shadowRadius * 0.3, 8)
        // macOS window corner radius is 10pt
        let nativeCornerRadius: CGFloat = 10

        let totalWidth = imgSize.width + padding * 2
        let totalHeight = imgSize.height + padding * 2

        // Pre-render mesh gradient outside the drawing handler to avoid @MainActor isolation issues
        let prerenderedMesh = prerenderBackground(config: config, width: Int(totalWidth), height: Int(totalHeight))

        var success = false
        let result = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            // Gradient background
            let bgRect = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
            context.saveGState()
            drawGradientBackground(in: bgRect, config: config, context: context, prerenderedMesh: prerenderedMesh)
            context.restoreGState()

            let imageRect = NSRect(x: padding, y: padding, width: imgSize.width, height: imgSize.height)

            // Draw the window image with shadow on top of the gradient.
            // The image has transparent corners, so the gradient shows through naturally.
            if shadowRadius > 0 {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = shadowRadius
                shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
                shadow.set()
            }
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            success = true
            return true
        }
        if !success {
            _ = result.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return success ? result : image
    }

    // MARK: - Rounded mode (just rounded corners, no title bar)

    private static func renderRounded(image: NSImage, config: BeautifyConfig) -> NSImage {
        let imgSize = image.size
        let padding = config.padding
        let cornerRadius = config.cornerRadius
        let shadowRadius = config.shadowRadius
        let shadowOffset = min(shadowRadius * 0.3, 8)

        let totalWidth = imgSize.width + padding * 2
        let totalHeight = imgSize.height + padding * 2

        // Pre-render mesh gradient outside the drawing handler to avoid @MainActor isolation issues
        let prerenderedMesh = prerenderBackground(config: config, width: Int(totalWidth), height: Int(totalHeight))

        var success = false
        let result = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return true
            }

            // Gradient background — fill entire canvas, no outer rounding
            let bgRect = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
            context.saveGState()
            drawGradientBackground(in: bgRect, config: config, context: context, prerenderedMesh: prerenderedMesh)
            context.restoreGState()

            let imageRect = NSRect(x: padding, y: padding, width: imgSize.width, height: imgSize.height)

            // Draw image with rounded corners + shadow in one pass
            context.saveGState()
            if shadowRadius > 0 {
                context.setShadow(offset: CGSize(width: 0, height: -shadowOffset),
                                  blur: shadowRadius,
                                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
            }
            // Begin a transparency layer so the shadow is cast by the clipped image shape
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            context.endTransparencyLayer()
            context.restoreGState()

            success = true
            return true
        }
        if !success {
            _ = result.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return success ? result : image
    }
}
