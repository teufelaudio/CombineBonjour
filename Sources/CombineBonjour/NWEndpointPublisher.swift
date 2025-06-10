// Copyright © 2021 Lautsprecher Teufel GmbH. All rights reserved.

import Combine
import Foundation
import Network
#if canImport(NetworkExtensions)
import NetworkExtensions
#elseif canImport(NetworkExtensionsDynamic)
import NetworkExtensionsDynamic
#endif

extension NWEndpoint {
    public func publisher() -> NWEndpointPublisher {
        publisher { description, monitorStrategy in
            NetService(domain: description.domain, type: description.type, name: description.serviceName).publisher(monitorDevice: monitorStrategy)
        }
    }

    public func publisher<P: Publisher>(netServicePublisher: @escaping (ServiceDescription, NetServiceTXTRecordsMonitorStrategy) -> P)
    -> NWEndpointPublisher where P.Output == NetServicePublisher.Output, P.Failure == NetServicePublisher.Failure {
        .init(endpoint: self, netServicePublisher: netServicePublisher)
    }
}

public struct NWEndpointPublisher {
    private let endpoint: NWEndpoint
    private let publishResolvedAddresses: Bool
    private let publishResolvedTXT: Bool
    private let netServicePublisherFactory: (ServiceDescription, NetServiceTXTRecordsMonitorStrategy)
        -> AnyPublisher<NetServicePublisher.Output, NetServicePublisher.Failure>

    public init<P: Publisher>(
        endpoint: NWEndpoint,
        netServicePublisher: @escaping (ServiceDescription, NetServiceTXTRecordsMonitorStrategy) -> P,
        publishResolvedAddresses: Bool = true,
        publishResolvedTXT: Bool = false
    ) where P.Output == NetServicePublisher.Output, P.Failure == NetServicePublisher.Failure {
        self.endpoint = endpoint
        self.netServicePublisherFactory = { netServicePublisher($0, $1).eraseToAnyPublisher() }
        self.publishResolvedAddresses = publishResolvedAddresses
        self.publishResolvedTXT = publishResolvedTXT
    }
}

extension NWEndpointPublisher: Publisher {
    public typealias Output = ResolvedEndpoint
    public typealias Failure = NWEndpointError

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        switch endpoint {
        case .hostPort, .unix, .url:
            // For these endpoints we don't need to do anything else, it's a sync operation
            // so we just feed the subscriber and complete the publisher immediately
            Just(.from(endpoint: endpoint, service: nil))
                .setFailureType(to: Failure.self)
                .subscribe(subscriber)

        case let .service(name, type, domain, interface):
            // In this case we will use the NetServicePublisher
            netServicePublisherFactory(
                ServiceDescription(serviceName: name, type: type, domain: domain),
                publishResolvedTXT ? .keepMonitoringTXTUpdates : .doNotMonitorTXTUpdates
            )
            .compactMap { event in
                switch event.type {
                case .willPublish, .willResolve, .didPublish, .didAcceptConnectionWith:
                    return nil
                case .didResolveAddress:
                    guard publishResolvedAddresses else { return nil }
                    let txt = event.netService.txtRecordData().map(NetService.dictionary(fromTXTRecord:))
                    return .service(event.netService, interface: interface, txt: txt)
                case let .didUpdateTXTRecord(txtRecord):
                    guard publishResolvedTXT else { return nil }
                    event.netService.setTXTRecord(NetService.data(fromTXTRecord: txtRecord))
                    return .service(event.netService, interface: interface, txt: txtRecord)
                }
            }
            .mapError(Failure.netServiceError)
            .subscribe(subscriber)

        @unknown default:
            Fail(error: .endpointIsNotSupported)
                .subscribe(subscriber)
        }
    }
}

// MARK: - Model
extension NWEndpointPublisher {
    public enum ResolvedEndpoint: Equatable {
        public enum HostType: Equatable {
            case name(String)
            case ip(NetworkExtensions.IP)
        }

        /// A host port endpoint represents an endpoint defined by the host and port.
        case hostPort(host: HostType, port: Int, interface: NWInterface?, txt: [String: Data]?)

        /// A service endpoint represents a Bonjour service
        case service(NetService, interface: NWInterface?, txt: [String: Data]?)

        /// A unix endpoint represents a path that supports connections using AF_UNIX domain sockets.
        case unix(path: String, txt: [String: Data]?)

        /// A URL endpoint represents an endpoint defined by a URL. Connection will parse out
        /// the hostname and appropriate port. Note that the scheme will not influence the protocol
        /// stack being used.
        @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
        case url(URL, txt: [String: Data]?)
    }

    public enum NWEndpointError: Error {
        /// This endpoint is not yet supported
        case endpointIsNotSupported

        /// Error emitted by NetServicePublisher
        case netServiceError(NetServicePublisher.Failure)
    }
}

extension NWEndpointPublisher.ResolvedEndpoint {
    public static func from(endpoint: NWEndpoint, service: NetService?) -> NWEndpointPublisher.ResolvedEndpoint {
        let txt = service?.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) }

        switch endpoint {
        case let .hostPort(host: host, port: port):
            // NWEndpoint.Host: great, no service resolution needed. However, it could be an address or a hostname.
            let port = Int(port.rawValue)

            switch host {
            case let .name(name, interface):
                return .hostPort(host: .name(name), port: port, interface: interface, txt: txt)
            case let .ipv4(v4):
                return .hostPort(host: .ip(IP.ipv4(v4)), port: port, interface: nil, txt: txt)
            case let .ipv6(v6):
                return .hostPort(host: .ip(IP.ipv6(v6)), port: port, interface: nil, txt: txt)
            @unknown default:
                fatalError("NWEndpoint.Host case not implemented: \(host)")
            }

        case let .service(name, type, domain, interface):
            return .service(
                service ?? NetService(domain: domain, type: type, name: name),
                interface: interface,
                txt: txt
            )
        case let .unix(path):
            // unix domain paths are unhandled
            return .unix(path: path, txt: txt)
        case let .url(url):
            return .url(url, txt: txt)
        @unknown default:
            fatalError("NWEndpoint case not implemented: \(endpoint)")
        }
    }

    public var interface: NWInterface? {
        switch self {
        case let .hostPort(_, _, interface, _): return interface
        case let .service(_, interface, _): return interface
        case .unix, .url: return nil
        }
    }

    public var txt: [String: Data]? {
        switch self {
        case let .hostPort(_, _, _, txt): return txt
        case let .service(_, _, txt): return txt
        case let .unix(_, txt): return txt
        case let .url(_, txt): return txt
        }
    }

    public var hostname: String? {
        switch self {
        case let .hostPort(.name(hostname), _, _, _): return hostname
        case let .service(service, _, _): return service.hostName
        case let .url(url, _): return url.host
        case let .hostPort(hostType, _, _, _):
            switch hostType {
            case let .name(host): return host
            case let .ip(addr): return addr.ipUrlString
            }
        case .unix: return nil
        }
    }

    public var ips: [String]? {
        switch self {
        case let .hostPort(.ip(ip), _, _, _): return [ip.ipString]
        case let .service(service, _, _): return service.parsedAddresses()
        case .hostPort(.name, _, _, _), .unix, .url: return nil
        }
    }

    public var port: Int? {
        switch self {
        case let .hostPort(_, port, _, _): return port
        case let .service(service, _, _): return service.port
        case let .url(url, _): return url.port
        case .unix: return nil
        }
    }
}
