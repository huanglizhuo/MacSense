import SwiftUI

struct EventLogView: View {
    let events:  [EventRecord]
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if events.isEmpty {
                emptyState
            } else {
                eventList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Event Log")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if !events.isEmpty {
                Text("(\(events.count))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !events.isEmpty {
                Button("Clear") { onClear() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 4) {
            Spacer()
            Text("No events detected")
                .font(.caption).foregroundStyle(.tertiary)
            Text("Tap the desk or tilt the MacBook")
                .font(.caption2).foregroundStyle(.quaternary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Event list

    private var eventList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(events) { event in
                    eventRow(event)
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    // MARK: - Row

    private func eventRow(_ ev: EventRecord) -> some View {
        HStack(spacing: 8) {
            // Severity badge
            Text(ev.type.rawValue)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(badgeColor(ev.type).cornerRadius(3))
                .fixedSize()

            // Time + magnitude + sources
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(ev.timestamp, format: .dateTime.hour().minute().second())
                        .font(.system(size: 11, design: .monospaced))
                    Text(String(format: "%.4f g", ev.magnitude))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !ev.sources.isEmpty {
                    Text(ev.sources.joined(separator: " · "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Magnitude bar (0–0.5 g = full width, fixed size — no GeometryReader needed)
            let frac = min(1.0, Double(ev.magnitude) / 0.5)
            RoundedRectangle(cornerRadius: 2)
                .fill(badgeColor(ev.type).opacity(0.5))
                .frame(width: max(1, 50 * frac), height: 8)
                .frame(width: 50, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(badgeColor(ev.type).opacity(ev.type.severity >= 3 ? 0.04 : 0))
    }

    // MARK: - Colour map

    private func badgeColor(_ type: EventRecord.EventType) -> Color {
        switch type {
        case .chocMajeur: return .red
        case .chocMoyen:  return Color(red: 1, green: 0.2, blue: 0)
        case .microChoc:  return .orange
        case .vibration:  return .yellow
        case .vibLegere:  return .teal
        case .microVib:   return .secondary
        }
    }
}

#Preview {
    EventLogView(events: [], onClear: {})
        .frame(width: 420, height: 220)
}
