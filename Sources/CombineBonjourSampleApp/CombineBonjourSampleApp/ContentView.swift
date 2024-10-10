// Copyright © 2023 Lautsprecher Teufel GmbH. All rights reserved.

import Combine
import CombineBonjour
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: Store

    var body: some View {
        NavigationStack {
            searchView
        }
    }

    var searchView: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .center) {
                Text("Combine Bonjour Sample")
                    .font(.headline)
                    .padding()
            }

            HStack(alignment: .center) {
                TextField(
                    "Service Name",
                    text: Binding(
                        get: { viewModel.state.serviceToSearch },
                        set: { viewModel.dispatch(.changeServiceToSearch($0)) }
                    )
                )
                .padding()

                Button(action: { viewModel.dispatch(.toggleDiscovery) }) {
                    Text(viewModel.state.isDiscovering ? "Stop" : "Start")
                }
                .padding()
            }

            viewModel.state.lastError.map { Text($0) }
                .padding()

            List(viewModel.state.discoveredServices) { service in
                Text(service.name)
                    .foregroundColor(service.isVisible ? .primary : .secondary)
                    .onTapGesture {
                        viewModel.dispatch(.tapService(service))
                    }
            }
            .navigationDestination(isPresented: .init(get: { viewModel.state.selectedService != nil },
                                                      set: { forward in if !forward { viewModel.dispatch(.backFromDetails) } })) {
                viewModel.state.selectedService.map {
                    serviceView(service: $0, extra: viewModel.state.resolvedService)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func serviceView(service: DiscoveredService, extra: NWEndpointPublisher.ResolvedEndpoint?) -> some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text(service.name).font(.headline)

                HStack {
                    Text("Hostname:")
                    Text(extra?.hostname ?? "")
                }

                HStack {
                    Text("IPs:")
                    Text((extra?.ips ?? []).joined(separator: ", "))
                }

                HStack {
                    Text("Port:")
                    Text((extra?.port).map { String($0) } ?? "")
                }

                HStack {
                    Text("Interface:")
                    Text(extra?.interface?.name ?? "")
                }

                Text("TXT Records:")
                ForEach(service.txt) { entry in
                    HStack {
                        Text("\(entry.key):").font(.caption)
                        Text("\(entry.value)").font(.caption)
                        Spacer()
                    }
                }
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
