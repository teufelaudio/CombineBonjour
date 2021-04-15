//
//  ContentView.swift
//  SampleApp
//
//  Created by Luiz Rodrigo Martins Barbosa on 15.04.21.
//

import Combine
import CombineBonjour
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: Store

    var body: some View {
        HSplitView {
            leftView

            rightView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var leftView: some View {
        VStack(alignment: .leading) {
            HStack {
                Spacer()
                Text("Combine Bonjour Sample")
                    .font(.headline)
                    .padding()
                Spacer()
            }

            HStack {
                Spacer()
                TextField(
                    "Service Name",
                    text: Binding(
                        get: { viewModel.state.serviceToSearch },
                        set: { viewModel.dispatch(.changeServiceToSearch($0)) }
                    )
                )
                Button(action: { viewModel.dispatch(.toggleDiscovery) }) {
                    Text(viewModel.state.isDiscovering ? "Stop" : "Start")
                }
                Spacer()
            }

            if let errorMessage = viewModel.state.lastError {
                Text(errorMessage)
            }

            List {
                ForEach(viewModel.state.discoveredServices) { service in
                    Text(service.name)
                        .foregroundColor(service.isVisible ? .primary : .secondary)
                        .onTapGesture {
                            viewModel.dispatch(.tapService(service))
                        }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    var rightView: some View {
        if let selected = viewModel.state.selectedService,
           let service = viewModel.state.discoveredServices.first(where: { $0.id == selected.id }) {
            serviceInfo(service: service, extra: selected.extraDetails)
        } else {
            Spacer()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func serviceInfo(service: DiscoveredService, extra: NWEndpointPublisher.ResolvedEndpoint?) -> some View {
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
