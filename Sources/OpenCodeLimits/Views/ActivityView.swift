import SwiftUI
import Charts
import OpenCodeLimitsCore

/// Activity screen: a daily or monthly bar chart (tokens or cost) selected by
/// period, summary tiles, recent sessions and top models. Only metadata is
/// shown — never prompt content.
struct ActivityView: View {
    let activity: ActivitySnapshot?
    @EnvironmentObject private var settings: Settings

    private var isCost: Bool { settings.activityMetric == "cost" }

    private var metricBinding: Binding<String> {
        Binding(
            get: { settings.activityMetric },
            set: { settings.activityMetric = $0 }
        )
    }

    private var periodBinding: Binding<Int> {
        Binding(
            get: { settings.activityPeriod },
            set: { settings.activityPeriod = $0 }
        )
    }

    private var usesMonthlyBuckets: Bool { settings.activityPeriod == 0 }

    var body: some View {
        Group {
            if let activity, !activity.events.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Период", selection: periodBinding) {
                            Text("7 дней").tag(7)
                            Text("30 дней").tag(30)
                            Text("90 дней").tag(90)
                            Text("Всё время").tag(0)
                        }
                        .pickerStyle(.segmented)

                        Text("Источник: \(activity.source.title)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Picker("Метрика", selection: metricBinding) {
                            Text("Токены").tag("tokens")
                            Text("$").tag("cost")
                        }
                        .pickerStyle(.segmented)

                        chart(for: activity, period: settings.activityPeriod)

                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 8
                        ) {
                            tile(title: "Всего токенов", value: Self.compact(activity.totalTokens))
                            tile(title: "Стоимость", value: Self.usd(activity.totalCost))
                            tile(
                                title: activity.source == .api ? "Шагов" : "Сообщений",
                                value: "\(activity.totalMessages)"
                            )
                            tile(
                                title: usesMonthlyBuckets ? "Месяцев с активностью" : "Дней с активностью",
                                value: "\(Self.activeDays(in: activity, monthly: usesMonthlyBuckets))"
                            )
                        }

                        sectionTitle("Последние сессии")
                        if activity.sessions.isEmpty {
                            Text("Сессий пока нет")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(activity.sessions.prefix(12))) { session in
                                sessionRow(session)
                            }
                        }

                        sectionTitle("Топ моделей")
                        if activity.models.isEmpty {
                            Text("Моделей пока нет")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            let maxTokens = max(activity.models.first?.tokens ?? 1, 1)
                            ForEach(Array(activity.models.prefix(6))) { model in
                                modelRow(model, maxTokens: maxTokens)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("Нет данных об активности")
                        .font(.headline)
                    if let source = activity?.source {
                        Text("Источник: \(source.title)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Активность появится после первых запросов в OpenCode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }

    /// Period 0 shows the whole history grouped by month; finite periods show
    /// a trailing slice of the ascending daily buckets.
    @ViewBuilder
    private func chart(for activity: ActivitySnapshot, period: Int) -> some View {
        if period == 0 {
            monthlyChart(activity.monthly)
        } else {
            dailyChart(Array(activity.daily.suffix(max(period, 0))))
        }
    }

    private func dailyChart(_ buckets: [ActivityBucket]) -> some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(
                    x: .value("Дата", bucket.start, unit: .day),
                    y: .value(
                        isCost ? "Стоимость" : "Токены",
                        isCost ? bucket.cost : Double(bucket.tokens)
                    )
                )
                .foregroundStyle(Color.accentColor.opacity(0.85))
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.day().month(.abbreviated))
                    }
                }
            }
        }
        .frame(height: 150)
    }

    private func monthlyChart(_ buckets: [ActivityBucket]) -> some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(
                    x: .value("Месяц", bucket.start, unit: .month),
                    y: .value(
                        isCost ? "Стоимость" : "Токены",
                        isCost ? bucket.cost : Double(bucket.tokens)
                    )
                )
                .foregroundStyle(Color.accentColor.opacity(0.85))
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.month(.abbreviated).year())
                    }
                }
            }
        }
        .frame(height: 150)
    }

    private func tile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 4)
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.title.isEmpty ? "Без названия" : session.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(Self.relative(session.lastActive))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(session.project.isEmpty ? "—" : session.project)
                Text("•")
                Text(session.model.isEmpty ? "—" : session.model)
                Spacer()
                Text(Self.compact(session.tokens))
                Text("•")
                Text(Self.usd(session.cost))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func modelRow(_ model: ModelBucket, maxTokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(model.providerID) / \(model.modelID)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(Self.compact(model.tokens))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: geometry.size.width
                                * CGFloat(Double(model.tokens) / Double(maxTokens))
                        )
                }
            }
            .frame(height: 5)
        }
    }

    // MARK: - Formatting

    private static func compact(_ value: Int) -> String {
        let divisor: Double
        let suffix: String
        switch abs(value) {
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "K"
        default:
            divisor = 1
            suffix = ""
        }

        guard divisor != 1 else { return "\(value)" }

        let number = Double(value) / divisor
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        let formatted = formatter.string(from: NSNumber(value: number))
            ?? String(format: "%.1f", number)
        return formatted + suffix
    }

    private static func usd(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "$%.2f", value)
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func activeDays(in snapshot: ActivitySnapshot, monthly: Bool) -> Int {
        let buckets = monthly ? snapshot.monthly : snapshot.daily
        return buckets.filter { $0.tokens > 0 || $0.messages > 0 }.count
    }
}
