//
//  Paint_All_the_Time__Watch_App.swift
//  Paint All the Time (Watch) Watch App
//
//  Created by Denis Kolchev on 19.09.2026.
//

import SwiftUI

@main
struct Paint_All_the_Time__Watch__Watch_AppApp: App {
    init() { WatchPhotoTransfer.shared.start() }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
