//
//  NetworkServiceBrowser.swift
//  CombineBonjour
//
//  Created by Thomas Mellenthin on 08.04.21.
//  Copyright © 2020 Lautsprecher Teufel GmbH. All rights reserved.
//

import Network
import Combine
import Foundation
import NetworkExtensions

public class NetworkServiceBrowser {
    private let serviceType: String
    private let domain: String?

    public init(
        serviceType: String,
        domain: String?
    ) {
        self.serviceType = serviceType
        self.domain = domain
    }
}

extension NetworkServiceBrowser: Publisher {
    public typealias Output = Event
    public typealias Failure = NetworkServiceBrowserError

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        let subscription = Subscription(
            subscriber: subscriber,
            serviceType: serviceType,
            domain: domain
        )
        subscriber.receive(subscription: subscription)
    }
}

extension NetworkServiceBrowser {
    private class Subscription<SubscriberType: Subscriber>: Combine.Subscription
    where SubscriberType.Input == Output, SubscriberType.Failure == Failure {
        private var buffer: DemandBuffer<SubscriberType>?
        private let browser: NWBrowser
        private let domain: String?
        private let serviceType: String

        // We need a lock to update the state machine of this Subscription
        private let lock = NSRecursiveLock()
        // The state machine here is only a boolean checking if the bonjour is browsing or not
        // If should start browsing when there's demand for the first time (not necessarily on subscription)
        // Only demand starts the side-effect, so we have to be very lazy and postpone the side-effects as much as possible
        private var started: Bool = false

        private var resolvers: Set<NetServiceResolver<SubscriberType>> = []

        init(subscriber: SubscriberType, serviceType: String, domain: String?) {
            let params: NWParameters = .tcp // init() // udp
            // params.prohibitExpensivePaths = true // do not browse WAN
            self.browser = NWBrowser(for: NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType,
                                                                                    domain: domain),
                                     using: params)
            self.buffer = DemandBuffer(subscriber: subscriber)
            self.domain = domain
            self.serviceType = serviceType

            browser.stateUpdateHandler = .some({ [weak self] state in
                switch state {
                case .setup:
                    break
                case .ready:
                    break
                case let .failed(error):
                    self?.handleError(error: error)
                case .cancelled:
                    break
                case let .waiting(error):
                    self?.handleError(error: error)
                @unknown default:
                    break
                }

            })
            browser.browseResultsChangedHandler = .some({ [weak self] (_ , changes: Set<NWBrowser.Result.Change>) in
                changes.forEach { change in
                    guard let strongSelf = self, let buffer = strongSelf.buffer else { return }

                    switch change {
                    case .identical:
                        break
                    case let .added(result):
                        strongSelf.serviceAdded(buffer: buffer, result: result)
                    case let .removed(result):
                        strongSelf.serviceRemoved(result: result)
                    case .changed(old: let old, new: let new, flags: let flags):
                        strongSelf.serviceChanged(old, new, flags)
                    @unknown default:
                        break
                    }
                }
            })
        }

        public func request(_ demand: Subscribers.Demand) {
            guard let buffer = self.buffer else { return }

            lock.lock()

            if !started && demand > .none {
                // There's demand, and it's the first demanded value, so we start browsing
                started = true
                lock.unlock()

                start()
            } else {
                lock.unlock()
            }

            // Flush buffer
            // If subscriber asked for 10 but we had only 3 in the buffer, it will return 7 representing the remaining demand
            // We actually don't care about that number, as once we buffer more items they will be flushed right away, so simply ignore it
            _ = buffer.demand(demand)
        }

        public func cancel() {
            buffer = nil
            started = false
            stop()
        }

        private func start() {
            browser.start(queue: .main)
        }

        private func stop() {
            browser.cancel()
        }

        // MARK: - NWBrowser helpers

        private func serviceAdded(buffer: DemandBuffer<SubscriberType>,
                                  result: NWBrowser.Result) {
            // we now can emit that we've found a service, but we may need to resolve it
            _ = buffer.buffer(value: .init(type: .didFind(serviceType: serviceType,
                                                          domain: domain,
                                                          result: result,
                                                          txt: txt(from: result))))
            // Service resolution depends on the Endpoint
            switch result.endpoint {
            case let .hostPort(host: host, port: port):
                // NWEndpoint.Host: great, no service resolution needed. However, it could be an address or a hostname.
                var ip: [IP] = []
                var hostname: String? = nil
                switch host {
                case let .name(name, _): hostname = name
                case let .ipv4(v4): ip.append(IP(v4))
                case let .ipv6(v6): ip.append(IP(v6))
                @unknown default: return
                }

                // serviceName is only available in the .service branch
                _ = buffer.buffer(value: .init(type: .didResolve(serviceName: "",
                                                                 serviceType: serviceType,
                                                                 domain: domain,
                                                                 result: result,
                                                                 txt: txt(from: result),
                                                                 addresses: ip,
                                                                 hostname: hostname,
                                                                 port: Int(port.rawValue))))

            case .service(name: let name, type: let type, domain: let domain, interface: _):
                // A service needs to be resolved first.
                let resolver = NetServiceResolver<SubscriberType>(serviceName: name,
                                                                  domain: domain,
                                                                  type: type,
                                                                  result: result,
                                                                  txt: txt(from: result),
                                                                  buffer: buffer)
                resolvers.insert(resolver)
                resolver.cleanup = { [weak self] in self?.resolvers.remove(resolver) }
            case .unix:
                // unix domain paths are unhandled
                break
            case let .url(url):
                guard let host = url.host else { return }

                // serviceName is only available in the .service branch
                _ = buffer.buffer(value: .init(type: .didResolve(serviceName: "",
                                                                 serviceType: serviceType,
                                                                 domain: domain,
                                                                 result: result,
                                                                 txt: txt(from: result),
                                                                 addresses: [],
                                                                 hostname: host,
                                                                 port: url.port.map { Int($0) } )))
            @unknown default:
                break
            }
        }

        private func serviceRemoved(result: NWBrowser.Result) {
            _ = buffer?.buffer(value: .init(type: .didRemove(serviceType: serviceType,
                                                             domain: domain,
                                                             result: result)))
        }

        private func serviceChanged(_ old: NWBrowser.Result, _ new: NWBrowser.Result, _ flags: NWBrowser.Result.Change.Flags) {
            _ = buffer?.buffer(value: .init(type: .didUpdate(serviceType: serviceType,
                                                             domain: domain,
                                                             old: old,
                                                             new: new,
                                                             newTxt: txt(from: new),
                                                             flags: flags)))
        }

        private func txt(from result: NWBrowser.Result) -> [String: String]? {
            var txtRecord: NWTXTRecord? = nil
            if case let .bonjour(txt) = result.metadata {
                txtRecord = txt
            }
            return txtRecord?.dictionary
        }

        private func handleError(error: NWError) {
            if case let .dns(dnsServiceErrorType) = error, dnsServiceErrorType == kDNSServiceErr_PolicyDenied {
                _ = buffer?.complete(completion: .failure(NetworkServiceBrowser.NetworkServiceBrowserError.bonjourPermissionDenied))
            } else {
                _ = buffer?.complete(completion: .failure(NetworkServiceBrowser.NetworkServiceBrowserError.didNotSearch(error: error)))
            }
        }
    }
}

// MARK: - Model
extension NetworkServiceBrowser {
    public struct Event {
        public let type: EventType

        public init(type: EventType) {
            self.type = type
        }
    }

    public enum EventType {
        /// A service was found.
        case didFind(serviceType: String, domain: String?, result: NWBrowser.Result, txt: [String: String]?)

        /// A previously discovered service is no longer published.
        case didRemove(serviceType: String, domain: String?, result: NWBrowser.Result)

        /// A previously discovered service changed. Usually this means, it was discovered or removed on another network interface. See flags.
        case didUpdate(serviceType: String,
                       domain: String?,
                       old: NWBrowser.Result,
                       new: NWBrowser.Result,
                       newTxt: [String: String]?,
                       flags: NWBrowser.Result.Change.Flags)

        case didResolve(serviceName: String,
                        serviceType: String,
                        domain: String?,
                        result: NWBrowser.Result,
                        txt: [String: String]?,
                        addresses: [IP],
                        hostname: String?,
                        port: Int?)
    }

    public enum NetworkServiceBrowserError: Error {
        /// The user needs to grant the app permissions to discover devices in the network.
        case bonjourPermissionDenied
        /// Any other error that can happen during discovery
        case didNotSearch(error: NWError)
        /// Resolver error
        case netServiceError(errorCode: Int, errorDomain: Int)
        /// Resolver Timeout
        case netServiceTimeout
    }
}

extension NetworkServiceBrowser {

    private class NetServiceResolver<SubscriberType: Subscriber>: NSObject, NetServiceDelegate
            where SubscriberType.Input == Output, SubscriberType.Failure == Failure {
        private let serviceName: String
        private let domain: String
        private let type: String
        private let result: NWBrowser.Result
        private let txt: [String: String]?
        private let netService: NetService
        private let buffer: DemandBuffer<SubscriberType>
        public var cleanup: (() -> Void)?

        public init(serviceName: String,
                    domain: String,
                    type: String,
                    result: NWBrowser.Result,
                    txt: [String: String]?,
                    buffer: DemandBuffer<SubscriberType>) {
            self.serviceName = serviceName
            self.domain = domain
            self.type = type
            self.result = result
            self.txt = txt
            self.netService = NetService(domain: domain, type: type, name: serviceName)
            self.buffer = buffer
            super.init()

            self.netService.delegate = self
            self.netService.resolve(withTimeout: 5.0)
        }

        public func netServiceDidResolveAddress(_ sender: NetService) {
            guard let addresses = sender.addresses else { return }

            let addr: [String] = addresses.compactMap {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                $0.withUnsafeBytes { ptr in
                    guard let sockaddr_ptr = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return /* ignoe error */ }
                    let sockaddr = sockaddr_ptr.pointee
                    guard getnameinfo(sockaddr_ptr,
                                      socklen_t(sockaddr.sa_len),
                                      &hostname,
                                      socklen_t(hostname.count),
                                      nil,
                                      0,
                                      NI_NUMERICHOST) == 0 else { return /* ignoe error */ }
                }
                return String(cString: hostname)
            }

            _ = self.buffer.buffer(value: .init(type: .didResolve(serviceName: serviceName,
                                                                  serviceType: type,
                                                                  domain: domain,
                                                                  result: result,
                                                                  txt: txt,
                                                                  addresses: addr.compactMap{ IP($0) },
                                                                  hostname: nil,
                                                                  port: sender.port)))
        }

        public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
            guard let errorDomain = errorDict["NSNetServicesErrorDomain"]?.intValue,
                  let errorCode = errorDict["NSNetServicesErrorCode"]?.intValue else { return }

            if errorCode == NetService.ErrorCode.timeoutError.rawValue {
                buffer.complete(completion: .failure(NetworkServiceBrowser.NetworkServiceBrowserError.netServiceTimeout))
                return
            }
            buffer.complete(completion: .failure(NetworkServiceBrowser.NetworkServiceBrowserError.netServiceError(errorCode: errorCode,
                                                                                                                      errorDomain: errorDomain)))
        }

        public func netServiceDidStop(_ sender: NetService) {
            cleanup?()
         }
    }
}
