//
//  ContentView.swift
//  Buzzer
//
//  A status panel — the app "literally just" receives push notifications, so
//  the UI is about showing whether that pipeline is wired up: permission,
//  device token, relay registration, and the last notification received.
//

import SwiftUI
import UserNotifications

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ContentView: View {
    @ObservedObject private var push = PushManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                authSection
                tokenSection
                relaySection
                activitySection
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("Buzzer").font(.largeTitle.bold())
                Text("Remote push, and literally nothing else.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Authorization

    private var authSection: some View {
        Card(title: "Notification permission") {
            HStack {
                Circle().fill(authColor).frame(width: 10, height: 10)
                Text(authText)
                Spacer()
            }
            if push.authorizationStatus == .denied {
                Button("Open Settings", action: openSettings)
            } else if push.authorizationStatus == .notDetermined {
                Button("Request permission") { push.requestAuthorizationAndRegister() }
            }
        }
    }

    private var authText: String {
        switch push.authorizationStatus {
        case .authorized: return "Authorized"
        case .denied: return "Denied — enable in Settings"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    private var authColor: Color {
        switch push.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .yellow
        }
    }

    // MARK: - Device token

    private var tokenSection: some View {
        Card(title: "APNs device token") {
            if let token = push.deviceToken {
                Text(token)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                Button {
                    copyToPasteboard(token)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            } else {
                Text("No token yet — granting permission produces one within a second or two.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Relay

    private var relaySection: some View {
        Card(title: "Relay") {
            TextField("http://localhost:8080", text: $push.relayURLString)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
            SecureField("Auth token (optional, = BUZZER_TOKEN)", text: $push.authToken)
                .textFieldStyle(.roundedBorder)
                .font(.system(.footnote, design: .monospaced))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            HStack {
                Button("Register with relay") {
                    Task { await push.registerWithRelay() }
                }
                .disabled(push.deviceToken == nil)
                Spacer()
            }
            Text(push.registrationStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        Card(title: "Activity") {
            LabeledRow(label: "Last notification", value: push.lastNotification ?? "—")
            if let err = push.lastError {
                LabeledRow(label: "Last error", value: err, valueColor: .red)
            }
        }
    }

    // MARK: - Helpers

    private func openSettings() {
        #if os(iOS) || os(visionOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

// MARK: - Small reusable views

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).foregroundStyle(valueColor).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
