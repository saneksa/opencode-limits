import Foundation
import CFNetwork
import SystemConfiguration

/// Builds URLSession configurations that honour the system HTTPS proxy set by
/// `scutil --proxy` (SCDynamicStoreCopyProxies), with an HTTPS_PROXY
/// environment-variable fallback. No proxy address is hardcoded.
public final class ProxyProvider: @unchecked Sendable {
    public static let shared = ProxyProvider()

    public init() {}

    public func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        if let proxy = systemProxyDictionary() ?? environmentProxyDictionary() {
            configuration.connectionProxyDictionary = proxy
        }
        return configuration
    }

    // MARK: - System configuration

    private func systemProxyDictionary() -> [AnyHashable: Any]? {
        guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return nil }
        let enabled = (settings[kSCPropNetProxiesHTTPSEnable as String] as? NSNumber)?.boolValue ?? false
        guard enabled else { return nil }
        guard let host = settings[kSCPropNetProxiesHTTPSProxy as String] as? String, !host.isEmpty else {
            return nil
        }
        let port = (settings[kSCPropNetProxiesHTTPSPort as String] as? NSNumber)?.intValue ?? 8080
        return proxyDictionary(host: host, port: port)
    }

    // MARK: - Environment fallback

    private func environmentProxyDictionary() -> [AnyHashable: Any]? {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["HTTPS_PROXY"] ?? environment["https_proxy"] ?? ""
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let withScheme = value.contains("://") ? value : "http://" + value
        guard let components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else { return nil }
        return proxyDictionary(host: host, port: components.port ?? 80)
    }

    private func proxyDictionary(host: String, port: Int) -> [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPSEnable as String: NSNumber(value: 1),
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: NSNumber(value: port),
        ]
    }
}
