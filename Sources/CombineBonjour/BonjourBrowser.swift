//
//  BonjourBrowser.swift
//  FoundationExtensions
//
//  Created by Luiz Barbosa on 06.03.20.
//  Copyright © 2020 Lautsprecher Teufel GmbH. All rights reserved.
//

import Combine
import Foundation

public struct BonjourBrowserType: Publisher {
    public typealias Output = BonjourBrowser.Event
    public typealias Failure = BonjourBrowser.BonjourBrowserError

    private let onReceive: (AnySubscriber<Output, Failure>) -> Void

    public init<P: Publisher>(publisher: P) where P.Output == Output, P.Failure == Failure {
        onReceive = publisher.receive(subscriber:)
    }

    public init(bonjourBrowser: BonjourBrowser) {
        self.init(publisher: bonjourBrowser)
    }

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        onReceive(AnySubscriber(subscriber))
    }
}

public class BonjourBrowser {
    private let domain: String
    private let serviceType: String
    private let serviceTypeFactory: (NetService) -> BonjourServiceType

    public init(
        serviceType: String,
        domain: String,
        serviceTypeFactory: @escaping (NetService) -> BonjourServiceType = { BonjourService(service: $0).erase() }
    ) {
        self.domain = domain
        self.serviceType = serviceType
        self.serviceTypeFactory = serviceTypeFactory
    }
}

extension BonjourBrowser: Publisher {
    public typealias Output = Event
    public typealias Failure = BonjourBrowserError

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        let subscription = Subscription(
            subscriber: subscriber,
            serviceType: serviceType,
            domain: domain,
            serviceTypeFactory: { BonjourServiceType.init(bonjourService: .init(service: $0)) }
        )
        subscriber.receive(subscription: subscription)
    }
}

extension BonjourBrowser {
    private class Subscription<SubscriberType: Subscriber>: NSObject, Combine.Subscription, NetServiceBrowserDelegate
    where SubscriberType.Input == Output, SubscriberType.Failure == Failure {
        private var buffer: DemandBuffer<SubscriberType>?
        private let browser: NetServiceBrowser
        private let domain: String
        private let serviceTypeFactory: (NetService) -> BonjourServiceType
        private let serviceType: String

        // We need a lock to update the state machine of this Subscription
        private let lock = NSRecursiveLock()
        // The state machine here is only a boolean checking if the bonjour is browsing or not
        // If should start browsing when there's demand for the first time (not necessarily on subscription)
        // Only demand starts the side-effect, so we have to be very lazy and postpone the side-effects as much as possible
        private var started: Bool = false

        init(subscriber: SubscriberType, serviceType: String, domain: String, serviceTypeFactory: @escaping (NetService) -> BonjourServiceType) {
            self.browser = NetServiceBrowser()
            self.buffer = DemandBuffer(subscriber: subscriber)
            self.domain = domain
            self.serviceType = serviceType
            self.serviceTypeFactory = serviceTypeFactory
            super.init()

            browser.delegate = self
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

        func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
            _ = buffer?.buffer(value: .init(netServiceBrowser: browser, type: .didFind(service: serviceTypeFactory(service), moreComing: moreComing)))
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
            _ = buffer?.buffer(value: .init(netServiceBrowser: browser, type: .didRemove(service: serviceTypeFactory(service), moreComing: moreComing)))
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
            buffer?.complete(completion: .failure(.didNotSearch(netServiceBrowser: browser, errorDict: errorDict)))
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didFindDomain domainString: String, moreComing: Bool) {
            _ = buffer?.buffer(value: .init(netServiceBrowser: browser, type: .didFindDomain(domainString: domainString, moreComing: moreComing)))
        }

        func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
            _ = buffer?.buffer(value: .init(netServiceBrowser: browser, type: .willSearch))
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didRemoveDomain domainString: String, moreComing: Bool) {
            _ = buffer?.buffer(value: .init(netServiceBrowser: browser, type: .didRemoveDomain(domainString: domainString, moreComing: moreComing)))
        }

        func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
            /// Sent to the NSNetServiceBrowser instance's delegate when the instance's previous running search request has stopped.
            buffer?.complete(completion: .finished)
        }

        private func start() {
            browser.searchForServices(ofType: serviceType, inDomain: domain)
        }

        private func stop() {
            browser.stop()
        }
    }
}

extension BonjourBrowser {
    public func erase() -> BonjourBrowserType {
        .init(bonjourBrowser: self)
    }
}

// MARK: - Model
extension BonjourBrowser {
    public struct Event {
        public let netServiceBrowser: NetServiceBrowser
        public let type: EventType

        public init(netServiceBrowser: NetServiceBrowser, type: EventType) {
            self.netServiceBrowser = netServiceBrowser
            self.type = type
        }
    }

    public enum EventType {
        /// Sent to the NSNetServiceBrowser instance's delegate before the instance begins a search.
        /// The delegate will not receive this message if the instance is unable to begin a search.
        /// Instead, the delegate will receive the -netServiceBrowser:didNotSearch: message.
        case willSearch

        /// Sent to the NSNetServiceBrowser instance's delegate for each domain discovered.
        /// If there are more domains, moreComing will be YES. If for some reason handling discovered domains requires significant processing,
        /// accumulating domains until moreComing is NO and then doing the processing in bulk fashion may be desirable.
        case didFindDomain(domainString: String, moreComing: Bool)

        /// Sent to the NSNetServiceBrowser instance's delegate for each service discovered.
        /// If there are more services, moreComing will be YES.
        /// If for some reason handling discovered services requires significant processing, accumulating services until moreComing is NO
        /// and then doing the processing in bulk fashion may be desirable.
        case didFind(service: BonjourServiceType, moreComing: Bool)

        /// Sent to the NSNetServiceBrowser instance's delegate when a previously discovered domain is no longer available.
        case didRemoveDomain(domainString: String, moreComing: Bool)

        /// Sent to the NSNetServiceBrowser instance's delegate when a previously discovered service is no longer published.
        case didRemove(service: BonjourServiceType, moreComing: Bool)
    }

    public enum BonjourBrowserError: Error {
        /// Sent to the NSNetServiceBrowser instance's delegate when an error in searching for domains or services has occurred.
        /// The error dictionary will contain two key/value pairs representing the error domain and code
        /// (see the NSNetServicesError enumeration above for error code constants).
        /// It is possible for an error to occur after a search has been started successfully.
        case didNotSearch(netServiceBrowser: NetServiceBrowser, errorDict: [String : NSNumber])
    }
}
