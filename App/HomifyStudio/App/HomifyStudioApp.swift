import AVFoundation
import SwiftUI
import UIKit

@main
struct HomifyStudioApp: App {
    @StateObject private var library = ProjectLibrary()

    init() {
        // .playback: audio is heard even with the silent switch on, as users
        // expect from a video editor.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    ThumbnailProvider.shared.purge()
                }
        }
    }
}
