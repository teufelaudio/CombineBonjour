// Copyright © 2021 Lautsprecher Teufel GmbH. All rights reserved.

import SwiftUI

@main
struct SampleAppApp: App {
    @StateObject var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: store)
        }
    }
}
