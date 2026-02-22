import SwiftUI

struct StatusBarLabelView: View {
    @EnvironmentObject var sensor: SensorManager
    @AppStorage("statusBarDisplayMode") private var mode: StatusBarDisplayMode = .all

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sensor.isConnected ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            modeContent
        }
        .frame(height: 16)
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .all:
            // Wrap in a single HStack so _ConditionalContent can wrap a unary view,
            // preventing the TupleView siblings from overlapping (ZStack-like) inside
            // the outer HStack when passed as an opaque `some View` child.
            HStack(spacing: 4) {
                spectrumBars
                valueText(String(format: "%+.0f°", sensor.snapshot.orientation.roll))
                valueText(String(format: "%.0f°",  sensor.snapshot.lidAngle))
                valueText(String(format: "%.0flx", sensor.snapshot.alsLux))
            }
        case .spectrum:
            spectrumBars
        case .accelMag:
            valueText(accelMagText)
        case .roll:
            valueText(String(format: "%+.0f°", sensor.snapshot.orientation.roll))
        case .pitch:
            valueText(String(format: "%+.0f°", sensor.snapshot.orientation.pitch))
        case .lux:
            valueText(String(format: "%.0flx", sensor.snapshot.alsLux))
        case .lidAngle:
            valueText(String(format: "%.0f°", sensor.snapshot.lidAngle))
        }
    }

    private var spectrumBars: some View {
        Canvas { ctx, size in
            let bands  = sensor.snapshot.spectrumBands
            let colors: [Color] = [.blue, .teal, .green, .orange, .red]
            let barW: CGFloat = 5
            let gap:  CGFloat = 1
            for (i, val) in bands.enumerated() {
                let h = max(2, size.height * CGFloat(val))
                let x = CGFloat(i) * (barW + gap)
                let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(colors[i].opacity(sensor.isConnected ? 0.9 : 0.35))
                )
            }
        }
        .frame(width: 5 * 5 + 4 * 1, height: 14)
    }

    private func valueText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    private var accelMagText: String {
        let v = sensor.snapshot.accelHistory.last ?? .zero
        let mag = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        return String(format: "%.3fg", mag)
    }
}
