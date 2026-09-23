import SwiftUI

/// Deleting a row turns it to dust: a soft edge erases it left to right while fine grains lift off
/// where the text was and drift away. The grains live in a layer above the list, so the row can
/// collapse (and the rows below glide up) while its dust is still floating.
enum Dust {
    /// Time for the erasing edge to cross the row.
    static let sweep = 0.34
    /// How long a burst stays around (sweep + the longest grain life).
    static let lifetime = 1.35
}

/// One row's worth of dust, in the list's visible coordinate space.
struct DustBurst: Identifiable {
    struct Grain {
        let x, y, dx, dy, size, life, delay, alpha: Double
        let tinted: Bool
    }

    let id = UUID()
    let rect: CGRect
    let start = Date()
    let grains: [Grain]

    init(rect: CGRect) {
        self.rect = rect
        let count = Int(min(320, max(150, rect.width * rect.height / 42)))
        grains = (0..<count).map { _ in
            let x = Double.random(in: 0...1)
            return Grain(
                x: x,
                y: Double.random(in: 0.18...0.82),
                dx: Double.random(in: 10...64),
                dy: Double.random(in: -48 ... -6),
                size: Double.random(in: 1.0...2.5),
                life: Double.random(in: 0.5...0.95),
                // Grains are released as the edge passes over them.
                delay: x * Dust.sweep + Double.random(in: 0...0.05),
                alpha: Double.random(in: 0.45...1.0),
                tinted: Double.random(in: 0...1) < 0.12
            )
        }
    }
}

/// Erases the row from left to right behind a soft edge.
struct DustErase: ViewModifier {
    let start: Date?

    func body(content: Content) -> some View {
        if let start {
            TimelineView(.animation) { timeline in
                let p = min(1, timeline.date.timeIntervalSince(start) / Dust.sweep)
                content.mask(Self.edge(p))
            }
        } else {
            content
        }
    }

    private static func edge(_ p: Double) -> LinearGradient {
        guard p < 1 else { return LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing) }
        let soft = 0.22
        let cut = p * (1 + soft) - soft
        let a = max(0, min(0.9999, cut))
        let b = max(a + 0.0001, min(1, cut + soft))
        return LinearGradient(stops: [.init(color: .clear, location: a), .init(color: .black, location: b)],
                              startPoint: .leading, endPoint: .trailing)
    }
}

/// Draws every active burst. Paused (no work at all) when there is no dust.
struct DustLayer: View {
    let bursts: [DustBurst]

    var body: some View {
        TimelineView(.animation(paused: bursts.isEmpty)) { timeline in
            Canvas { ctx, _ in
                for burst in bursts {
                    let t = timeline.date.timeIntervalSince(burst.start)
                    for g in burst.grains {
                        let age = t - g.delay
                        guard age > 0, age < g.life else { continue }
                        let k = age / g.life
                        let ease = 1 - (1 - k) * (1 - k)
                        let x = burst.rect.minX + g.x * burst.rect.width + g.dx * ease + sin((age + g.x) * 9) * 1.4
                        let y = burst.rect.minY + g.y * burst.rect.height + g.dy * ease
                        let size = g.size * (1 - k * 0.4)
                        let alpha = g.alpha * pow(1 - k, 1.4)
                        let color = g.tinted ? Theme.accent : Theme.foreground
                        ctx.fill(Path(ellipseIn: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)),
                                 with: .color(color.opacity(alpha)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
