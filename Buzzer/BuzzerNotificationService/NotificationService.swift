//
//  NotificationService.swift
//  BuzzerNotificationService
//
//  Turns a Buzzer push into a communication notification when it carries a
//  custom `sender` and/or `icon`: the banner then shows a round sender avatar +
//  display name in place of the Buzzer glyph, so you can tell at a glance which
//  app / Claude session / job buzzed you.
//
//  The relay sets `mutable-content: 1` only when `icon`/`sender` are present, so
//  plain pushes skip all of this and render unchanged.
//

import CryptoKit
import ImageIO
import Intents
import os
import UserNotifications

private let log = Logger(subsystem: "com.melissaefoster.Buzzer.BuzzerNotificationService",
                         category: "icons")

final class NotificationService: UNNotificationServiceExtension {

    /// Reject avatars larger than this. NSEs have a hard ~24 MB memory ceiling,
    /// and an avatar only needs to be small — a cap keeps a large or hostile URL
    /// from getting the extension jetsammed mid-download.
    private static let maxIconBytes = 2 * 1024 * 1024

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    // The download Task and serviceExtensionTimeWillExpire() run on different
    // threads and both want to deliver. This guards delivery to exactly once.
    private let lock = NSLock()
    private var didDeliver = false

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let best = request.content.mutableCopy() as? UNMutableNotificationContent
        bestAttemptContent = best

        guard let best else {
            deliver(request.content)
            return
        }

        let info = request.content.userInfo
        let sender = (info["sender"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconURLString = (info["icon"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Not a communication push — deliver as-is.
        guard (sender?.isEmpty == false) || (iconURLString?.isEmpty == false) else {
            deliver(best)
            return
        }

        work = Task {
            let updated = await self.communicationContent(base: best,
                                                          request: request,
                                                          sender: sender,
                                                          iconURLString: iconURLString)
            self.deliver(updated ?? best)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // The avatar fetch ran past the deadline — cancel it and deliver the
        // plain banner so the notification is never dropped.
        work?.cancel()
        if let bestAttemptContent {
            deliver(bestAttemptContent)
        }
    }

    /// Calls the system content handler exactly once; the second caller (timeout
    /// vs. async completion, whichever loses the race) is a no-op.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        if didDeliver {
            lock.unlock()
            return
        }
        didDeliver = true
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }

    // MARK: - Communication notification

    /// Builds (and donates) an INSendMessageIntent so the system restyles the
    /// notification with a sender avatar + name. Returns nil on any failure, so
    /// the caller falls back to the plain banner.
    private func communicationContent(base: UNMutableNotificationContent,
                                      request: UNNotificationRequest,
                                      sender: String?,
                                      iconURLString: String?) async -> UNNotificationContent? {
        // The conversation id groups messages from the same sender; reuse the
        // push's thread-id when present.
        let threadID = request.content.threadIdentifier
        let displayName = (sender?.isEmpty == false ? sender! : nil)
            ?? (base.title.isEmpty ? "Buzzer" : base.title)
        let conversationID = threadID.isEmpty ? displayName : threadID

        var avatar: INImage?
        if let iconURLString, !iconURLString.isEmpty,
           let data = await avatarData(for: iconURLString) {
            // INImage(imageData:) embeds the bytes, so the system renderer (a
            // separate process) doesn't need to read our sandboxed cache file.
            avatar = INImage(imageData: data)
        }
        // Avatar fetch failure is non-fatal: a comms notification without an
        // image still shows the sender name with a monogram.

        let handle = INPersonHandle(value: conversationID, type: .unknown)
        let person = INPerson(personHandle: handle,
                              nameComponents: nil,
                              displayName: displayName,
                              image: avatar,
                              contactIdentifier: nil,
                              customIdentifier: nil)

        let intent = INSendMessageIntent(recipients: nil,
                                         outgoingMessageType: .outgoingMessageText,
                                         content: base.body,
                                         speakableGroupName: nil,
                                         conversationIdentifier: conversationID,
                                         serviceName: nil,
                                         sender: person,
                                         attachments: nil)
        // The avatar only actually renders when it's set on the intent via
        // setImage(forParameterNamed:) — the INPerson image alone is not enough
        // (confirmed across several Apple devforum threads). That API is
        // unavailable on native macOS, so Mac builds fall back to the INPerson
        // image (and may not show an avatar — a macOS platform limitation).
        #if !os(macOS)
        if let avatar {
            intent.setImage(avatar, forParameterNamed: \.sender)
        }
        #endif

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            return try base.updating(from: intent)
        } catch {
            log.error("communication notification failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Avatar cache

    /// Returns the avatar image bytes, downloading them once and caching them
    /// keyed by the URL. Repeated icons (the common case) skip the network.
    /// Rejects oversized or non-image payloads so a bad URL can't poison the
    /// cache or crash the extension.
    private func avatarData(for urlString: String) async -> Data? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("buzzer-icons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // sha256 of the URL is the cache key — opaque, collision-resistant, and
        // not attacker-controllable (no path traversal, no caller-set extension).
        let dest = dir.appendingPathComponent(sha256(urlString))

        if let cached = try? Data(contentsOf: dest), !cached.isEmpty {
            log.debug("icon cache hit: \(urlString, privacy: .public)")
            return cached
        }

        log.debug("icon cache miss, downloading: \(urlString, privacy: .public)")
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log.error("icon download failed: bad response for \(urlString, privacy: .public)")
                return nil
            }
            guard !data.isEmpty, data.count <= Self.maxIconBytes else {
                log.error("icon rejected: \(data.count) bytes (cap \(Self.maxIconBytes))")
                return nil
            }
            guard Self.isImageData(data) else {
                log.error("icon rejected: not a decodable image")
                return nil
            }
            // Caching is best-effort; a write failure just means we re-download.
            try? data.write(to: dest, options: .atomic)
            return data
        } catch {
            log.error("icon download error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// True if the bytes decode as an image (PNG/JPEG/GIF/HEIC/…). Guards against
    /// caching HTML/JSON/garbage that a misconfigured icon URL might return.
    private static func isImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0 else { return false }
        return true
    }

    private func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
