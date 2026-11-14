import SwiftUI

@main
struct TVRemoteApp: App {
    @State private var session = RemoteSession()

    var body: some Scene {
        WindowGroup {
            RemoteView(session: session)
                .preferredColorScheme(.dark)
                .task { session.start() }
        }
    }
}
