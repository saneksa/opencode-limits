import SwiftUI
import AppKit
import OpenCodeLimitsCore

/// Local tab selection. Kept in an ObservableObject because `@State` relies on
/// a compiler macro plugin that is not shipped with every CommandLineTools SDK.
final class TabSelection: ObservableObject {
    @Published var tab = "limits"
}

/// The window shown when the menu-bar item is clicked.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var selection = TabSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            updatedLine

            if let error = state.errorMessage {
                errorBanner(error)
            }

            Picker("Экран", selection: $selection.tab) {
                Text("Лимиты").tag("limits")
                Text("Активность").tag("activity")
            }
            .pickerStyle(.segmented)

            Group {
                if state.isRefreshing && state.usage == nil {
                    ProgressView("Загрузка…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if selection.tab == "limits" {
                    ScrollView {
                        VStack(spacing: 8) {
                            if let usage = state.usage {
                                ForEach(usage.meters) { row in
                                    UsageMeterView(row: row)
                                }
                            } else {
                                Text("Нет данных о лимитах")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 120)
                            }
                        }
                    }
                } else {
                    ActivityView(activity: state.activity)
                        .environmentObject(state.settings)
                }
            }

            footnote
            Divider()

            HStack {
                Button("Обновить") {
                    state.refresh(requestActivity: true)
                }
                Spacer()
                Button("Настройки") {
                    SettingsWindowController.shared.show(state: state)
                }
                Button("Выход") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 380, height: 560)
        .onAppear {
            state.refreshOnOpen()
        }
    }

    private var header: some View {
        HStack {
            Text("OpenCode Go")
                .font(.headline)
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .help(statusHelp)
        }
    }

    private var updatedLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(updatedText(at: context.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func updatedText(at now: Date) -> String {
        guard let last = state.lastUpdated else { return "Обновлено: ещё не обновлялось" }
        let seconds = max(0, Int(now.timeIntervalSince(last)))
        if seconds < 60 { return "Обновлено \(seconds) сек назад" }
        let minutes = seconds / 60
        if minutes < 60 { return "Обновлено \(minutes) мин назад" }
        return "Обновлено \(minutes / 60) ч назад"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Повторить") {
                state.refresh(requestActivity: true)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var footnote: some View {
        Text("5 ч — 20% месячного лимита, окно стартует с первого запроса; неделя — 50%, сброс пн 00:00 UTC")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusColor: Color {
        guard let usage = state.usage else { return .gray }
        if usage.meters.contains(where: { $0.meter.isRateLimited }) { return .red }
        if usage.worst.percent >= 85 { return .red }
        if usage.worst.percent >= 60 { return .orange }
        return .green
    }

    private var statusHelp: String {
        guard let usage = state.usage else { return "Нет данных" }
        if usage.meters.contains(where: { $0.meter.isRateLimited }) { return "Лимит исчерпан" }
        return "Наибольшая загрузка: \(usage.worst.percent)%"
    }
}
