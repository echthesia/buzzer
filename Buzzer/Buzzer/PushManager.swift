//
//  PushManager.swift
//  Buzzer
//
//  The whole brain of the app: request notification permission, register for
//  remote (APNs) notifications, hand the resulting device token to the relay,
//  and surface incoming notifications to the UI.
//

import Combine
import Foundation
import UserNotifications

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class PushManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushManager()

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var deviceToken: String?
    @Published var registrationStatus = "Waiting for permission…"
    @Published var lastNotification: String?
    @Published var lastError: String?

    /// Base URL of the Buzzer relay. Persisted so it survives relaunches.
    @Published var relayURLString: String {
        didSet { UserDefaults.standard.set(relayURLString, forKey: Self.relayURLKey) }
    }

    /// Optional bearer token; must match the relay's BUZZER_TOKEN. Persisted.
    @Published var authToken: String {
        didSet { UserDefaults.standard.set(authToken, forKey: Self.authTokenKey) }
    }

    private static let relayURLKey = "relayURL"
    private static let authTokenKey = "relayAuthToken"
    private static let defaultRelayURL = "http://localhost:8080"

    private override init() {
        relayURLString = UserDefaults.standard.string(forKey: Self.relayURLKey) ?? Self.defaultRelayURL
        authToken = UserDefaults.standard.string(forKey: Self.authTokenKey) ?? ""
        super.init()
    }

    private var platformName: String {
        #if os(macOS)
        return "macos"
        #elseif os(visionOS)
        return "visionos"
        #else
        return "ios"
        #endif
    }

    // MARK: - Lifecycle

    /// Called once at launch from the app delegate.
    func bootstrap() {
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorizationStatus()
        requestAuthorizationAndRegister()
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    /// Ask for permission, and only register for remote notifications once the
    /// user has actually granted it — registering before the prompt resolves
    /// produces flaky token delivery.
    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                self.refreshAuthorizationStatus()
                if let error {
                    self.lastError = "Authorization error: \(error.localizedDescription)"
                    return
                }
                guard granted else {
                    self.registrationStatus = "Notifications not authorized"
                    return
                }
                self.registerForRemoteNotifications()
            }
        }
    }

    private func registerForRemoteNotifications() {
        registrationStatus = "Registering with APNs…"
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    // MARK: - APNs token

    func setDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        registrationStatus = "Got device token — registering with relay…"
        Task { await registerWithRelay() }
    }

    func registrationFailed(_ error: Error) {
        lastError = "APNs registration failed: \(error.localizedDescription)"
        registrationStatus = "Failed to register for remote notifications"
    }

    // MARK: - Relay

    /// POST the device token to the relay's /register endpoint so it knows
    /// where to deliver pushes.
    func registerWithRelay() async {
        guard let token = deviceToken else {
            registrationStatus = "No device token yet"
            return
        }
        var base = relayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/register") else {
            lastError = "Invalid relay URL: \(relayURLString)"
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            req.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token, "platform": platformName])

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(code) {
                registrationStatus = "Registered with relay ✓"
                lastError = nil
            } else {
                registrationStatus = "Relay responded with HTTP \(code)"
            }
        } catch {
            registrationStatus = "Relay unreachable"
            lastError = "Could not reach relay: \(error.localizedDescription)"
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even while the app is in the foreground — handy for
    /// the demo loop, since otherwise foregrounded apps suppress the banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        recordNotification(notification.request.content)
        return [.banner, .sound, .badge]
    }

    /// Called when the user taps a delivered notification. If the payload
    /// carried a "url" custom key, open it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        recordNotification(content)
        if let urlString = content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            openURL(url)
        }
    }

    private func recordNotification(_ content: UNNotificationContent) {
        let title = content.title.isEmpty ? "(no title)" : content.title
        let headline = content.body.isEmpty ? title : "\(title) — \(content.body)"
        if let urlString = content.userInfo["url"] as? String {
            lastNotification = "\(headline)  ↪ \(urlString)"
        } else {
            lastNotification = headline
        }
    }

    private func openURL(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
