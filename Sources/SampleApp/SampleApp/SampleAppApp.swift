//
//  SampleAppApp.swift
//  SampleApp
//
//  Created by Luiz Rodrigo Martins Barbosa on 15.04.21.
//

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
