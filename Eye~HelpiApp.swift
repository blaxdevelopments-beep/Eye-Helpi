//
//  Eye_HelpiApp.swift
//  Eye~Helpi
//

import SwiftUI

@main
struct Eye_HelpiApp: App {

    init() {
        // The Opportunistic Uplink Engine watches for valid paths from the
        // first second, so queued syncs drain on its own terms.
        UplinkEngine.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}