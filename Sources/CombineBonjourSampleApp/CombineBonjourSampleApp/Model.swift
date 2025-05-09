// Copyright © 2023 Lautsprecher Teufel GmbH. All rights reserved.

import Combine
import CombineBonjour
import Foundation
import Network
import NetworkExtensions

struct DiscoveredService: Hashable, Identifiable {
    init(endpoint: NWEndpoint, txtString: [String: String]?, isVisible: Bool) {
        self.endpoint = endpoint
        self.txt = TXTEntry.entries(from: txtString)
        self.isVisible = isVisible
    }

    init(endpoint: NWEndpoint, txtData: [String : Data]?, isVisible: Bool) {
        self.endpoint = endpoint
        self.txt = TXTEntry.entries(from: txtData)
        self.isVisible = isVisible
    }

    var id: NWEndpoint { endpoint }
    let endpoint: NWEndpoint
    var txt: [TXTEntry]
    let isVisible: Bool

    struct TXTEntry: Hashable, Identifiable {
        var id: String { key }
        let key: String
        let value: String

        static func entries(from txtString: [String: String]?) -> [TXTEntry] {
            txtString?.map(TXTEntry.init) ?? []
        }

        static func entries(from txtData: [String: Data]?) -> [TXTEntry] {
            txtData.map { $0.mapValues { String(data: $0, encoding: .utf8) ?? "" } }?.map(TXTEntry.init) ?? []
        }
    }

    var name: String {
        switch endpoint {
        case let .hostPort(.name(hostname, _), port):
            return "\(hostname):\(port)"
        case let .hostPort(.ipv4(ip), port):
            return "\(IP(ip).ipString):\(port)"
        case let .hostPort(.ipv6(ip), port):
            return "\(IP(ip).ipString):\(port)"
        case let .service(name, _, _, _):
            return name
        case let .unix(path):
            return path
        case let .url(url):
            return url.absoluteString
        case .opaque(_):
            return "Not implemented"
        @unknown default:
            return "Not implemented"
        }
    }
}

struct ServiceDetails: Equatable {
    let id: DiscoveredService.ID
    var extraDetails: NWEndpointPublisher.ResolvedEndpoint?
}

struct State: Equatable {
    var discoveredServices: [DiscoveredService]
    var isDiscovering: Bool
    var lastError: String?
    var serviceToSearch: String
    var selectedService: DiscoveredService?
    var resolvedService: NWEndpointPublisher.ResolvedEndpoint?

    static let initial = State(
        discoveredServices: [],
        isDiscovering: false,
        lastError: nil,
        serviceToSearch: "_airplay._tcp",
        selectedService: nil,
        resolvedService: nil
    )
}

enum Action {
    case toggleDiscovery
    case changeServiceToSearch(String)
    case discoveryStarted
    case discoveryFinished(Error?)
    case discovered(endpoint: NWEndpoint, txt: [String: String]?)
    case lost(endpoint: NWEndpoint)
    case updated(endpoint: NWEndpoint, txt: [String: Data]?)
    case tapService(DiscoveredService)
    case backFromDetails
    case serviceResolutionFinished(Error?)
    case getInfoAboutService(NWEndpoint)
    case gotInfoAboutService(NWEndpointPublisher.ResolvedEndpoint)
}

class Store: ObservableObject {
    @Published var state = State.initial
    var discovery: AnyCancellable?
    var serviceResolution: AnyCancellable?

    func dispatch(_ action: Action) {
        let stateCopy = state

        switch action {
        case let .changeServiceToSearch(newValue):
            state.serviceToSearch = newValue
            if state.isDiscovering {
                stop()
            }

        case .toggleDiscovery:
            if state.isDiscovering {
                stop()
            } else {
                start(service: state.serviceToSearch)
            }

        case let .tapService(service):
            if state.selectedService?.id == service.id {
                state.selectedService = nil
                serviceResolution = nil
            } else {
                state.selectedService = service
                dispatch(.getInfoAboutService(service.endpoint))
            }

        case .backFromDetails:
            state.selectedService = nil

        case .discoveryStarted:
            state.isDiscovering = true
            state.lastError = nil
            state.discoveredServices = []

        case let .discoveryFinished(error):
            state.isDiscovering = false
            if let brwoserError = error as? NWBrowserPublisher.NWBrowserError, brwoserError.isBonjourPermissionDenied {
                state.lastError = "Permission to use local network has not been granted 😢"
            } else {
                state.lastError = error?.localizedDescription
            }

        case let .discovered(endpoint, txt):
            state.discoveredServices += [.init(endpoint: endpoint, txtString: txt, isVisible: true)]

        case let .updated(endpoint, txt):
            let item = DiscoveredService(endpoint: endpoint, txtData: txt, isVisible: true)
            if let index = state.discoveredServices.firstIndex(where: { $0.endpoint == endpoint }) {
                state.discoveredServices.remove(at: index)
                state.discoveredServices.insert(item, at: index)
            } else {
                state.discoveredServices.append(item)
            }

        case let .lost(endpoint):
            state.discoveredServices = state.discoveredServices.filter { $0.endpoint != endpoint }

        case let .serviceResolutionFinished(error):
            state.lastError = error?.localizedDescription ?? state.lastError

        case let .getInfoAboutService(endpoint):
            serviceResolution = endpoint.publisher()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { [weak self] completion in self?.dispatch(.serviceResolutionFinished(completion.failure)) },
                    receiveValue: { [weak self] resolved in self?.dispatch(.gotInfoAboutService(resolved)) }
                )

        case let .gotInfoAboutService(resolved):
            state.resolvedService = resolved
            if let index = state.discoveredServices.firstIndex(where: { $0.id == state.selectedService?.id }) {
                state.discoveredServices[index].txt = DiscoveredService.TXTEntry.entries(from: resolved.txt) 
            }
        }

        print("action: \(action)")
        if stateCopy != state {
            print("\t-\t\(stateCopy)\n\t+\t\(state)")
        }
    }

    private func start(service: String) {
        discovery = NWBrowser(for: .bonjourWithTXTRecord(type: service, domain: nil), using: .tcp).publisher
            .receive(on: DispatchQueue.main)
            .handleEvents(
                receiveCancel: { [weak self] in self?.dispatch(.discoveryFinished(nil)) },
                receiveRequest: { [weak self] demand in
                    if demand > .zero {
                        self?.dispatch(.discoveryStarted)
                    }
                }
            )
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.dispatch(.discoveryFinished(completion.failure))
                },
                receiveValue: { [weak self] event in
                    switch event {
                    case let .didFind(endpoint, txt):
                        self?.dispatch(.discovered(endpoint: endpoint, txt: txt))
                    case let .didRemove(endpoint, _):
                        self?.dispatch(.lost(endpoint: endpoint))
                    case .didUpdate:
                        break
                    }
                }
            )
    }

    private func stop() {
        discovery = nil
    }
}

extension Subscribers.Completion {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
