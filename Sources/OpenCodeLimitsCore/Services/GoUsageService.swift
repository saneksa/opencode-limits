import Foundation

/// Fetches the three Go usage windows from `GET /inference/go/v1/usage`.
/// The API key is obtained from the injected provider on every fetch and is
/// never stored, printed or included in an error message.
public final class GoUsageService: @unchecked Sendable {
    private let keyProvider: () throws -> String
    /// Injected session for tests. When nil, a fresh session is created for
    /// EVERY request from the current system proxy settings. Otherwise a
    /// session built while a proxy was enabled keeps pointing at the old
    /// 127.0.0.1:<port> after the proxy is switched off, and every poll fails
    /// with "Ошибка сети" until the app is restarted.
    private let injectedSession: URLSession?

    public init(keyProvider: @escaping () throws -> String, session: URLSession? = nil) {
        self.keyProvider = keyProvider
        self.injectedSession = session
    }

    private func makeSession() -> (URLSession, Bool) {
        if let injectedSession { return (injectedSession, false) }
        return (
            URLSession(configuration: ProxyProvider.shared.sessionConfiguration()),
            true
        )
    }

    public func fetch() async throws -> UsageSnapshot {
        let key: String
        do {
            key = try keyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.missingKey
        }
        guard !key.isEmpty else { throw UsageError.missingKey }

        var request = URLRequest(url: AppConfig.usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (session, shouldInvalidate) = makeSession()
        defer {
            if shouldInvalidate { session.finishTasksAndInvalidate() }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("Получен некорректный ответ сервера.")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw UsageError.invalidKey
        case 403:
            throw UsageError.noSubscription(Self.subscriptionMessage(from: data))
        default:
            throw UsageError.network("HTTP \(http.statusCode)")
        }

        do {
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            return UsageSnapshot(
                rolling: decoded.usage.rolling ?? .unknown,
                weekly: decoded.usage.weekly ?? .unknown,
                monthly: decoded.usage.monthly ?? .unknown,
                fetchedAt: Date()
            )
        } catch {
            throw UsageError.decoding(error.localizedDescription)
        }
    }

    private struct UsageResponse: Decodable {
        let usage: UsagePayload
    }

    private struct UsagePayload: Decodable {
        let rolling: UsageMeter?
        let weekly: UsageMeter?
        let monthly: UsageMeter?
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorDetail?
    }

    private struct ErrorDetail: Decodable {
        let message: String?
    }

    private static func subscriptionMessage(from data: Data) -> String {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let message = envelope.error?.message, !message.isEmpty else {
            return "Подписка OpenCode Go не активна."
        }
        return message
    }
}
