import SwiftUI

@main
struct HelloWorldApp: App {
    var body: some Scene {
        WindowGroup("Hello World") {
            Text("Hello, world!")
                .frame(width: 320, height: 200)
        }
    }
}
