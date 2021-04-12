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

public struct NetworkServiceBrowserType: Publisher {
    public typealias Output = NetworkServiceBrowser.Event
    public typealias Failure = NetworkServiceBrowser.NetworkServiceBrowserError

    private let onReceive: (AnySubscriber<Output, Failure>) -> Void

    public init<P: Publisher>(publisher: P) where P.Output == Output, P.Failure == Failure {
        onReceive = publisher.receive(subscriber:)
    }

    public init(bonjourBrowser: NetworkServiceBrowser) {
        self.init(publisher: bonjourBrowser)
    }

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        onReceive(AnySubscriber(subscriber))
    }
}

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

        init(subscriber: SubscriberType, serviceType: String, domain: String?) {
            let params: NWParameters = .init() // udp
            params.prohibitExpensivePaths = true // do not browse WAN
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
                    _ = self?.buffer?.complete(completion: .failure(NetworkServiceBrowser.NetworkServiceBrowserError.didNotSearch(error: error)))
                case .cancelled:
                    break
                case let .waiting(error):
                    if case let .dns(dnsServiceErrorType) = error, dnsServiceErrorType == kDNSServiceErr_PolicyDenied {
                        _ = self?.buffer?.complete(completion: .failure(NetworkServiceBrowser.NetworkServiceBrowserError.bonjourPermissionDenied))
                    } else {
                        _ = self?.buffer?.complete(completion: .failure(NetworkServiceBrowser.NetworkServiceBrowserError.didNotSearch(error: error)))
                    }
                @unknown default:
                    break
                }

            })
            browser.browseResultsChangedHandler = .some({ [weak self] (_ , changes: Set<NWBrowser.Result.Change>) in
                changes.forEach { change in
                    switch change {
                    case .identical:
                        break
                    case let .added(result):
                        var txtRecord: NWTXTRecord? = nil
                        if case let .bonjour(txt) = result.metadata {
                            txtRecord = txt
                        }
                        _ = self?.buffer?.buffer(value: .init(type: .didFind(name: serviceType, domain: domain, result: result, txt: txtRecord)))
                    case let .removed(result):
                        _ = self?.buffer?.buffer(value: .init(type: .didRemove(name: serviceType, domain: domain, result: result)))
                    case .changed(old: let old, new: let new, flags: let flags):
                        _ = self?.buffer?.buffer(value: .init(type: .didUpdate(name: serviceType, domain: domain, old: old, new: new, flags: flags)))
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
    }
}

extension NetworkServiceBrowser {
    public func erase() -> NetworkServiceBrowserType {
        .init(bonjourBrowser: self)
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
        case didFind(name: String, domain: String?, result: NWBrowser.Result, txt: NWTXTRecord?)

        /// A previously discovered service is no longer published.
        case didRemove(name: String, domain: String?, result: NWBrowser.Result)

        /// A previously discovered service changed. Usually this means, it was discovered or removed on another network interface. See flags.
        case didUpdate(name: String, domain: String?, old: NWBrowser.Result, new: NWBrowser.Result, flags: NWBrowser.Result.Change.Flags)
    }

    public enum NetworkServiceBrowserError: Error {
        /// The user needs to grant the app permissions to discover devices in the network.
        case bonjourPermissionDenied
        /// Any other error that can happen during discovery
        case didNotSearch(error: NWError)
    }
}
