import SwiftUI
import Charts

struct StatusBarPopupView: View {
    @EnvironmentObject var sensor: SensorManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("statusBarDisplayMode") private var displayMode: StatusBarDisplayMode = .all

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                Divider()
                accelGyroSection
                Divider()
                orientationSection
                Divider()
                spectrumSection
                Divider()
                environmentSection
                Divider()
                displaySelectorSection
            }
        }
        .frame(width: 280)
        .frame(maxHeight: 500)
        .background(.background)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sensor.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(sensor.isConnected ? sensor.deviceName : "Not connected")
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Button("Open Dashboard") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Accel / Gyro

    private var accelGyroSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Accel / Gyro")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    axisLabel("ax", color: .red,   value: sensor.snapshot.accelHistory.last?.x ?? 0, unit: "g")
                    axisLabel("ay", color: .green,  value: sensor.snapshot.accelHistory.last?.y ?? 0, unit: "g")
                    axisLabel("az", color: .blue,   value: sensor.snapshot.accelHistory.last?.z ?? 0, unit: "g")
                }
                GridRow {
                    axisLabel("gx", color: .red,   value: sensor.snapshot.gyroHistory.last?.x ?? 0, unit: "°/s")
                    axisLabel("gy", color: .green,  value: sensor.snapshot.gyroHistory.last?.y ?? 0, unit: "°/s")
                    axisLabel("gz", color: .blue,   value: sensor.snapshot.gyroHistory.last?.z ?? 0, unit: "°/s")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func axisLabel(_ name: String, color: Color, value: Float, unit: String) -> some View {
        HStack(spacing: 2) {
            Text(name)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(String(format: "%+.3f", value))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Orientation

    private var orientationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Orientation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            miniOrientationBar(label: "Roll",  value: sensor.snapshot.orientation.roll,  color: .blue,   range: -180...180)
            miniOrientationBar(label: "Pitch", value: sensor.snapshot.orientation.pitch, color: .green,  range: -90...90)
            miniOrientationBar(label: "Yaw",   value: sensor.snapshot.orientation.yaw,   color: .orange, range: -180...180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func miniOrientationBar(label: String, value: Float, color: Color, range: ClosedRange<Float>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            GeometryReader { geo in
                let frac    = Double((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let clamped = max(0, min(1, frac))
                let midFrac = 0.5
                let barStart = min(clamped, midFrac) * geo.size.width
                let barWidth = abs(clamped - midFrac) * geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.12))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.7))
                        .frame(width: barWidth, height: geo.size.height)
                        .offset(x: barStart)
                }
            }
            .frame(height: 6)
            Text(String(format: "%+.1f°", value))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 42, alignment: .trailing)
        }
    }

    // MARK: - Spectrum

    private var spectrumSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Vibration Spectrum")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart(makeSpectralBands(from: sensor.snapshot.spectrumBands)) { band in
                BarMark(
                    x: .value("Band", band.label),
                    y: .value("Energy", band.value)
                )
                .foregroundStyle(band.color.gradient)
                .cornerRadius(2)
            }
            .chartYScale(domain: 0...1)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { v in
                    AxisValueLabel {
                        if let s = v.as(String.self) {
                            Text(s).font(.system(size: 8))
                        }
                    }
                }
            }
            .frame(height: 60)
            .animation(.easeOut(duration: 0.1), value: sensor.snapshot.spectrumBands)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Environment

    private var environmentSection: some View {
        HStack(spacing: 12) {
            Label(String(format: "%.0f°", sensor.snapshot.lidAngle), systemImage: "macbook")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(String(format: "%.0f lx", sensor.snapshot.alsLux), systemImage: "sun.max")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Status Bar Display Selector

    private var displaySelectorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status Bar Display")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(StatusBarDisplayMode.allCases) { mode in
                modeSelectorRow(mode)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func modeSelectorRow(_ mode: StatusBarDisplayMode) -> some View {
        let isSelected = displayMode == mode
        let iconName   = isSelected ? "checkmark.circle.fill" : "circle"
        let iconColor: Color = isSelected ? .accentColor : .secondary
        return Button {
            displayMode = mode
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                Text(mode.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Text(liveValue(for: mode))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func liveValue(for mode: StatusBarDisplayMode) -> String {
        let snap = sensor.snapshot
        switch mode {
        case .all:
            let peak = snap.spectrumBands.max() ?? 0
            return String(format: "%+.0f° %.0f° %.0f%%", snap.orientation.roll, snap.lidAngle, peak * 100)
        case .spectrum:
            let peak = snap.spectrumBands.max() ?? 0
            return String(format: "%.0f%%", peak * 100)
        case .accelMag:
            let v = snap.accelHistory.last ?? .zero
            let mag = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
            return String(format: "%.3fg", mag)
        case .roll:
            return String(format: "%+.1f°", snap.orientation.roll)
        case .pitch:
            return String(format: "%+.1f°", snap.orientation.pitch)
        case .lux:
            return String(format: "%.0f lx", snap.alsLux)
        case .lidAngle:
            return String(format: "%.0f°", snap.lidAngle)
        }
    }
}

#Preview {
    StatusBarPopupView()
        .environmentObject(SensorManager())
}
