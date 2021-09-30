//
//  SCIONTestApp.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 15.03.21.
//

import SwiftUI

#if os(macOS)
struct VideoStatsWindowView: View {
    @ObservedObject var scionStack = SCIONStack.shared
    
    var body: some View {
        ScrollView {
            if scionStack.initialized {
                VideoCallStatsView(detailed: true, lastPenalties: [])
            }
        }
    }
}
#endif

@main
struct SCIONTestApp: App {
    init() {
        // App Nap slows down apps in background considerably. CPU allowance is drastically resuced to the point where many things no longer work like timers, sending packets starts taking hundreds of milliseconds, messing all sorts of things up. https://stackoverflow.com/questions/62360214/how-to-prevent-timer-slowing-down-in-background
        ProcessInfo().beginActivity(options: .userInitiated, reason: "Aint nobody got time for App Nap")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .windowToolbarStyle(UnifiedCompactWindowToolbarStyle())
        
        #if os(macOS)
        WindowGroup("Video Call Stats") {
            VideoStatsWindowView()
            .frame(minWidth: 300, minHeight: 450)
            .handlesExternalEvents(preferring: Set(arrayLiteral: "stats"), allowing: Set(arrayLiteral: "*")) // activate existing window if exists
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "stats")) // create new window if one doesn't exist
        #endif
    }
}
