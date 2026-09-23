import SwiftUI

@main
struct NIRMacApp: App {
    var body: some Scene {
        WindowGroup("NIR-M-R2") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
