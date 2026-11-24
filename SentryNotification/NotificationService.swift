import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var delivery: (content: UNNotificationContent, handler: (UNNotificationContent) -> Void)?
    private var task: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        let content = request.content
        let camera = ShareGroup.sentryPreviewCamera
        guard let info = content.userInfo as? [String: Any],
              info["type"] as? String == "sentry",
              let kind = info["kind"] as? String, ["alarm", "warning", "test"].contains(kind),
              let event = info["eventId"] as? String,
              event.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              ShareGroup.settings.mode == "automatic" || ShareGroup.settings.mode == nil,
              let tunnel = ShareGroup.tunnel,
              let base = ShareClient.tunnelEndpoint(tunnel.url),
              !tunnel.cookie.isEmpty, tunnel.cookie.utf8.count <= 4096,
              tunnel.cookie.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 59 }),
              let url = URL(string: base.absoluteString + "/api/sentry/image/" + event + "/" + (kind == "test" ? "test" : camera.rawValue))
        else { handler(content); return }

        lock.withLock {
            delivery = (content, handler)
            task = Task {
                let preview = try? await Self.photo(url: url, cookie: tunnel.cookie)
                guard !Task.isCancelled else { return }
                guard ShareGroup.tunnel == tunnel, ShareGroup.settings.mode == "automatic" || ShareGroup.settings.mode == nil,
                      kind == "test" || ShareGroup.sentryPreviewCamera == camera, let preview,
                      let updated = content.mutableCopy() as? UNMutableNotificationContent else {
                    finish()
                    return
                }
                updated.attachments = [preview]
                finish(updated)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish(_ updated: UNNotificationContent? = nil) {
        let pending = lock.withLock {
            let pending = delivery
            delivery = nil
            task?.cancel()
            task = nil
            return pending
        }
        if let pending { pending.handler(updated ?? pending.content) }
    }

    private static func photo(url: URL, cookie: String) async throws -> UNNotificationAttachment {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("galaxy_session=" + cookie, forHTTPHeaderField: "Cookie")
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")

        let limit = 2 * 1024 * 1024
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "image/jpeg", http.expectedContentLength <= limit else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard data.starts(with: [0xFF, 0xD8, 0xFF]) else { throw URLError(.cannotDecodeContentData) }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return try UNNotificationAttachment(identifier: "sentry-image", url: target)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
