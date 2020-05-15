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
            // This will either buffer or flush the items right away.
            // If subscriber asked for 10 but we had only 3 in the buffer, it will return 7 representing the remaining demand
            // We actually don't care about that number, as once we buffer more items they will be flushed right away, so simply ignore it
            _ = buffer?.buffer(value: .init(sender: browser, type: .foundService(serviceTypeFactory(service))))
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
            // This will either buffer or flush the items right away.
            // If subscriber asked for 10 but we had only 3 in the buffer, it will return 7 representing the remaining demand
            // We actually don't care about that number, as once we buffer more items they will be flushed right away, so simply ignore it
            _ = buffer?.buffer(value: .init(sender: browser, type: .removeService(serviceTypeFactory(service))))
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
            buffer?.complete(completion: .failure(.didNotSearch(errorDict)))
        }

        func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
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
        public let sender: NetServiceBrowser
        public let type: EventType

        public init(sender: NetServiceBrowser, type: EventType) {
            self.sender = sender
            self.type = type
        }
    }

    public enum EventType {
        case foundService(BonjourServiceType)
        case removeService(BonjourServiceType)
    }

    public enum BonjourBrowserError: Error {
        case didNotSearch([String: NSNumber])
    }
}
