import SwiftUI

struct OrientationView: View {
    let orientation: (roll: Float, pitch: Float, yaw: Float)

    private var roll:  Float { orientation.roll  }
    private var pitch: Float { orientation.pitch }
    private var yaw:   Float { orientation.yaw   }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Orientation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            Divider()

            VStack(spacing: 12) {
                orientationGauge(label: "Roll",  value: roll,  color: .blue,   range: -180...180)
                orientationGauge(label: "Pitch", value: pitch, color: .green,  range: -90...90)
                orientationGauge(label: "Yaw",   value: yaw,   color: .orange, range: -180...180)
            }
            .padding(12)

            Divider()

            // Horizon indicator
            horizonIndicator
                .padding(12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Gauge

    private func orientationGauge(label: String, value: Float, color: Color, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1f°", value))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.12))
                    let fraction = Double((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                    let clamped  = max(0, min(1, fraction))
                    let midFrac  = Double((0 - range.lowerBound) / (range.upperBound - range.lowerBound))

                    let barStart = min(clamped, midFrac) * geo.size.width
                    let barWidth = abs(clamped - midFrac) * geo.size.width

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.7))
                        .frame(width: barWidth, height: geo.size.height)
                        .offset(x: barStart)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Artificial horizon

    private var horizonIndicator: some View {
        Canvas { ctx, size in
            let cx = size.width  / 2
            let cy = size.height / 2
            let r  = min(cx, cy) - 2

            // Background circle
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: 2*r, height: 2*r)),
                with: .color(.black.opacity(0.05))
            )

            // Horizon line, tilted by roll, offset by pitch
            let rollRad  = Double(roll) * .pi / 180
            let pitchOff = Double(pitch) / 90 * r

            ctx.withCGContext { cg in
                cg.saveGState()
                cg.beginPath()
                cg.addEllipse(in: CGRect(x: cx-r, y: cy-r, width: 2*r, height: 2*r))
                cg.clip()

                cg.saveGState()
                cg.translateBy(x: cx, y: cy + pitchOff)
                cg.rotate(by: rollRad)

                // Sky
                cg.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
                cg.fill(CGRect(x: -r*2, y: -r*2, width: r*4, height: r*2))
                // Ground
                cg.setFillColor(NSColor.systemBrown.withAlphaComponent(0.25).cgColor)
                cg.fill(CGRect(x: -r*2, y: 0, width: r*4, height: r*2))
                // Horizon line
                cg.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
                cg.setLineWidth(1.5)
                cg.move(to: CGPoint(x: -r, y: 0))
                cg.addLine(to: CGPoint(x: r, y: 0))
                cg.strokePath()

                cg.restoreGState()
                cg.restoreGState()
            }

            // Center cross
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: cx - 10, y: cy))
                    p.addLine(to: CGPoint(x: cx + 10, y: cy))
                    p.move(to: CGPoint(x: cx, y: cy - 10))
                    p.addLine(to: CGPoint(x: cx, y: cy + 10))
                },
                with: .color(.white.opacity(0.7)),
                lineWidth: 1.5
            )

            // Border
            ctx.stroke(
                Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: 2*r, height: 2*r)),
                with: .color(.secondary.opacity(0.3)),
                lineWidth: 1
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 90)
    }
}

#Preview {
    OrientationView(orientation: (roll: 15, pitch: -5, yaw: 30))
        .frame(width: 220, height: 340)
}
