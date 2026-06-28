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
import Intents
import os
import UserNotifications

private let log = Logger(subsystem: "com.melissaefoster.Buzzer.BuzzerNotificationService",
                         category: "icons")

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let best = request.content.mutableCopy() as? UNMutableNotificationContent
        bestAttemptContent = best

        guard let best else {
            contentHandler(request.content)
            return
        }

        let info = request.content.userInfo
        let sender = (info["sender"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconURLString = info["icon"] as? String

        // Not a communication push — deliver as-is.
        guard (sender?.isEmpty == false) || (iconURLString?.isEmpty == false) else {
            contentHandler(best)
            return
        }

        Task {
            let updated = await self.communicationContent(base: best,
                                                          request: request,
                                                          sender: sender,
                                                          iconURLString: iconURLString)
            contentHandler(updated ?? best)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // The avatar fetch ran past the deadline — deliver the plain banner so the
        // notification is never dropped.
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
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
        if let iconURLString, !iconURLString.isEmpty {
            if let file = await cachedAvatarFile(for: iconURLString) {
                avatar = INImage(url: file)
            }
            // Avatar fetch failure is non-fatal: a comms notification without an
            // image still shows the sender name with a monogram.
        }

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
        // The sender's INPerson image becomes the avatar for a one-to-one
        // conversation; setImage(forParameterNamed:) is only needed for groups
        // (and is unavailable on native macOS), so we rely on the INPerson image.

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

    /// Returns a local file URL for the icon, downloading it once and caching it
    /// keyed by the URL. Repeated icons (the common case) skip the network.
    private func cachedAvatarFile(for urlString: String) async -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("buzzer-icons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        let dest = dir.appendingPathComponent(sha256(urlString)).appendingPathExtension(ext)

        if fm.fileExists(atPath: dest.path) {
            log.debug("icon cache hit: \(urlString, privacy: .public)")
            return dest
        }

        log.debug("icon cache miss, downloading: \(urlString, privacy: .public)")
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                log.error("icon download failed: bad response for \(urlString, privacy: .public)")
                return nil
            }
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            log.error("icon download error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
