import SwiftUI

struct WaveformView: View {
    var level: CGFloat
    var isMuted: Bool
    var accent: Color
    var height: CGFloat = 90

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let idle = 0.07 + 0.03 * sin(t * 1.3)
            let live = max(0.0, min(level, 1.0))
            let amp = max(0.04, isMuted ? idle : live)
            let speed = isMuted ? 1.25 : 1.85

            Canvas { context, size in
                let midY = size.height / 2
                let width = size.width
                let base = midY * amp

                let phases: [CGFloat] = [0.0, 0.85, 1.7]
                let weights: [CGFloat] = [1.0, 0.62, 0.38]

                for idx in 0..<phases.count {
                    let phase = CGFloat(t) * speed + phases[idx]
                    let amplitude = base * weights[idx]
                    let path = wavePath(width: width, midY: midY, amplitude: amplitude, phase: phase)

                    let opacity = isMuted ? 0.20 + (weights[idx] * 0.16) : 0.42 + (weights[idx] * 0.48)
                    let color = accent.opacity(opacity)

                    // soft glow layer
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 6))
                        layer.opacity = isMuted ? 0.24 : 0.55
                        layer.stroke(path, with: .color(color), lineWidth: 5)
                    }
                    // crisp stroke
                    context.stroke(path, with: .color(color), lineWidth: 2.6)
                }
            }
            .frame(height: height)
        }
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func wavePath(width: CGFloat, midY: CGFloat, amplitude: CGFloat, phase: CGFloat) -> Path {
        var path = Path()
        let points = 70
        for i in 0...points {
            let x = CGFloat(i) / CGFloat(points) * width
            let relative = CGFloat(i) / CGFloat(points)
            let sine = sin(relative * .pi * 2 + phase)
            let envelope = sin(relative * .pi)
            let y = midY + sine * amplitude * envelope
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
