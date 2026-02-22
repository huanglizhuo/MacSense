import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sensor: SensorManager

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            HSplitView {
                leftPanel
                rightPanel
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .alert("Permission Required", isPresented: $sensor.permissionDenied) {
            Button("Open System Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apple Motion needs Input Monitoring permission to read the built-in accelerometer.\n\nGo to System Settings → Privacy & Security → Input Monitoring and enable this app.")
        }
    }

    // MARK: Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sensor.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(sensor.isConnected ? sensor.deviceName : "Device not found")
                .font(.caption)
                .foregroundStyle(.secondary)

            if sensor.isConnected {
                Divider().frame(height: 10)
                Label(String(format: "Lid %.0f°", sensor.snapshot.lidAngle), systemImage: "macbook")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Divider().frame(height: 10)
                Label(String(format: "%.0f lx", sensor.snapshot.alsLux), systemImage: "sun.max")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            if !sensor.isConnected {
                Text("Apple Silicon MacBook required")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Panels

    private var leftPanel: some View {
        VStack(spacing: 1) {
            WaveformView(
                title: "Accelerometer (g)",
                history: sensor.snapshot.accelHistory,
                colors: [.red, .green, .blue]
            )
            Divider()
            WaveformView(
                title: "Gyroscope (°/s)",
                history: sensor.snapshot.gyroHistory,
                colors: [.orange, .teal, .purple]
            )
        }
        .frame(minWidth: 380)
    }

    private var rightPanel: some View {
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                OrientationView(orientation: sensor.snapshot.orientation)
                Divider()
                SpectralView(bands: sensor.snapshot.spectrumBands)
            }
            Divider()
            EventLogView(events: sensor.events, onClear: sensor.clearEvents)
        }
        .frame(minWidth: 380)
    }
}

#Preview {
    ContentView()
        .environmentObject(SensorManager())
}
