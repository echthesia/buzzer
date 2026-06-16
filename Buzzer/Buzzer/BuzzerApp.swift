//
//  BuzzerApp.swift
//  Buzzer
//
//  Created by Melissa Foster on 5/28/26.
//

import SwiftUI

@main
struct BuzzerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
