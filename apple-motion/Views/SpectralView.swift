import SwiftUI
import Charts

// Shared model used by both SpectralView and StatusBarPopupView.
struct SpectralBand: Identifiable {
    let id:    Int
    let label: String
    let value: Double
    let color: Color
}

private let spectralBandLabels: [String] = ["3 Hz", "6 Hz", "12 Hz", "25 Hz", "50 Hz"]
private let spectralBandColors: [Color]  = [.blue, .teal, .green, .orange, .red]

func makeSpectralBands(from bands: [Float]) -> [SpectralBand] {
    zip(bands.indices, bands).map { i, v in
        SpectralBand(id: i, label: spectralBandLabels[i], value: Double(v), color: spectralBandColors[i])
    }
}

struct SpectralView: View {
    let bands: [Float]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Vibration Spectrum")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            Divider()

            Chart(makeSpectralBands(from: bands)) { band in
                BarMark(
                    x: .value("Band", band.label),
                    y: .value("Energy", band.value)
                )
                .foregroundStyle(band.color.gradient)
                .cornerRadius(3)
                .annotation(position: .top, alignment: .center) {
                    Text(String(format: "%.0f%%", band.value * 100))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1.0]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%.0f%%", v * 100))
                                .font(.system(size: 8))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { v in
                    AxisValueLabel {
                        if let s = v.as(String.self) {
                            Text(s).font(.system(size: 8))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .animation(.easeOut(duration: 0.1), value: bands)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    SpectralView(bands: [0.1, 0.4, 0.7, 0.3, 0.2])
        .frame(width: 220, height: 280)
}
