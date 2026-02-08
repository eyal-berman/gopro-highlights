//
//  GoPro_HighlightApp.swift
//  GoPro Highlight
//
//  Created by Eyal Berman on 06/02/2026.
//

import SwiftUI

@main
struct GoPro_HighlightApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandMenu("Support") {
                Button("How To Use Features") {
                    NotificationCenter.default.post(name: .openHelpCenter, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])

                Button("Report a Bug") {
                    NotificationCenter.default.post(name: .openBugReporter, object: nil)
                }
            }
        }
    }
}
