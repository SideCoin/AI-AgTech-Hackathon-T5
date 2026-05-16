//
//  GlassesNotesApp.swift
//  GlassesNotes
//
//  Created by Shizun Yang on 5/15/26.
//

import MWDATCore
import SwiftUI

@main
struct GlassesNotesApp: App {
    init() {
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Wearables SDK configure failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    Task {
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                }
        }
    }
}
