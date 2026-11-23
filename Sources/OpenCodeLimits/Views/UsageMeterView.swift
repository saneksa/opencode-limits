import SwiftUI
import OpenCodeLimitsCore

/// A single usage card: big percentage, capsule progress bar, live reset
/// countdown and an optional "limit exhausted" badge.
struct UsageMeterView: View {
    let row: MeterRow

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.headline)
                Spacer(minLength: 6)
                if row.meter.isRateLimited {
                    Text("Лимит исчерпан")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.red))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(row.meter.percent)%")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if let reset = row.meter.resetsAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .trailing, spacing: 2) {
                            if let countdown = countdownText(from: context.date, reset: reset) {
                                Text("до сброса: \(countdown)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Сброс: \(reset.formatted(Date.FormatStyle(date: .numeric, time: .shortened)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.16))
                    Capsule()
                        .fill(accent)
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 9)

            if row.id == "rolling" {
                Text("окно начинается с первого запроса")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var progress: CGFloat {
        CGFloat(min(max(row.meter.percent, 0), 100)) / 100
    }

    private var accent: Color {
        if row.meter.isRateLimited || row.meter.percent >= 85 { return .red }
        if row.meter.percent >= 60 { return .orange }
        return .green
    }

    private func countdownText(from now: Date, reset: Date) -> String? {
        let remaining = reset.timeIntervalSince(now)
        if remaining <= 0 { return "ожидание сброса" }
        let totalMinutes = Int(remaining / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours) ч \(minutes) мин" }
        return "\(minutes) мин"
    }
}
