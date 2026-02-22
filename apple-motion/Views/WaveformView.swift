import SwiftUI

/// Draws three-axis sparkline waveform using Canvas.
struct WaveformView: View {
    let title:   String
    let history: [SIMD3<Float>]
    let colors:  [Color]        // [X, Y, Z]

    private let windowSize = 500  // samples shown

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                axisLegend
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Canvas { ctx, size in
                drawWaveform(ctx: ctx, size: size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var axisLegend: some View {
        HStack(spacing: 6) {
            ForEach(Array(zip(["X", "Y", "Z"], colors)), id: \.0) { label, color in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 2)
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Drawing

    private func drawWaveform(ctx: GraphicsContext, size: CGSize) {
        guard !history.isEmpty else { return }

        let samples = history.suffix(windowSize)
        let n = samples.count
        guard n > 1 else { return }

        // Compute dynamic range across all three axes
        var maxAbs: Float = 0.001
        for s in samples { maxAbs = max(maxAbs, abs(s.x), abs(s.y), abs(s.z)) }
        let scale = Double(maxAbs)

        let midY   = size.height / 2
        let scaleY = (size.height / 2 - 4) / scale

        func path(forAxis keyPath: KeyPath<SIMD3<Float>, Float>) -> Path {
            var p = Path()
            var idx = 0
            for s in samples {   // ArraySlice — no Array() conversion needed
                let x = Double(idx) / Double(n - 1) * Double(size.width)
                let y = midY - Double(s[keyPath: keyPath]) * scaleY
                if idx == 0 { p.move(to: CGPoint(x: x, y: y)) }
                else         { p.addLine(to: CGPoint(x: x, y: y)) }
                idx += 1
            }
            return p
        }

        // Grid center line
        var grid = Path()
        grid.move(to: CGPoint(x: 0, y: midY))
        grid.addLine(to: CGPoint(x: Double(size.width), y: midY))
        ctx.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

        // Waveforms
        let axes: [KeyPath<SIMD3<Float>, Float>] = [\.x, \.y, \.z]
        for (i, kp) in axes.enumerated() {
            let color = i < colors.count ? colors[i] : .white
            ctx.stroke(path(forAxis: kp), with: .color(color.opacity(0.9)), lineWidth: 1.0)
        }

        // Scale label
        let labelText = String(format: "±%.3f", scale)
        ctx.draw(
            Text(labelText).font(.system(size: 9)).foregroundStyle(.secondary),
            at: CGPoint(x: 4, y: 6),
            anchor: .topLeading
        )
    }
}


#Preview {
    let mock: [SIMD3<Float>] = (0..<200).map { i in
        SIMD3(sin(Float(i) * 0.1), cos(Float(i) * 0.07), sin(Float(i) * 0.13) * 0.5)
    }
    return WaveformView(title: "Accelerometer (g)", history: mock, colors: [.red, .green, .blue])
        .frame(width: 400, height: 160)
}
