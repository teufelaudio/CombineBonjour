//
//  BonjourService.swift
//  FoundationExtensions
//
//  Created by Luiz Barbosa on 06.03.20.
//  Copyright © 2020 Lautsprecher Teufel GmbH. All rights reserved.
//

import Combine
import Foundation

public struct BonjourServiceType: Publisher {
    public typealias Output = BonjourService.Event
    public typealias Failure = BonjourService.BonjourServiceError

    private let onReceive: (AnySubscriber<Output, Failure>) -> Void
    private let getName: () -> String
    private let getTxtRecordData: () -> [String: Data]?
    public var name: String {
        getName()
    }

    public var txtRecordData: [String: Data]? {
        getTxtRecordData()
    }

    public init<P: Publisher>(publisher: P, getName: @escaping () -> String, getTxtRecordData: @escaping () -> [String: Data]?)
    where P.Output == Output, P.Failure == Failure {
        onReceive = publisher.receive(subscriber:)
        self.getName = getName
        self.getTxtRecordData = getTxtRecordData
    }

    public init(bonjourService: BonjourService) {
        self.init(publisher: bonjourService, getName: { bonjourService.name }, getTxtRecordData: { bonjourService.txtRecordData })
    }

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        onReceive(AnySubscriber(subscriber))
    }
}

public class BonjourService {
    public var name: String {
        service.name
    }

    public var txtRecordData: [String: Data]? {
        service.txtRecordData().map(
            NetService.dictionary(fromTXTRecord:)
        )
    }

    private let service: NetService

    public init(service: NetService) {
        self.service = service
    }
}

extension BonjourService: Publisher {
    public typealias Output = Event
    public typealias Failure = BonjourServiceError

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        let subscription = Subscription(subscriber: subscriber, service: service)
        subscriber.receive(subscription: subscription)
    }
}

extension BonjourService {
    private class Subscription<SubscriberType: Subscriber>: NSObject, Combine.Subscription, NetServiceDelegate
    where SubscriberType.Input == Output, SubscriberType.Failure == Failure {
        private var buffer: DemandBuffer<SubscriberType>?
        private let service: NetService

        // We need a lock to update the state machine of this Subscription
        private let lock = NSRecursiveLock()
        // The state machine here is only a boolean checking if the bonjour is browsing or not
        // If should start browsing when there's demand for the first time (not necessarily on subscription)
        // Only demand starts the side-effect, so we have to be very lazy and postpone the side-effects as much as possible
        private var started: Bool = false

        init(subscriber: SubscriberType, service: NetService) {
            self.service = service
            self.buffer = DemandBuffer(subscriber: subscriber)
            super.init()

            service.delegate = self
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

        func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
            // This will either buffer or flush the items right away.
            // If subscriber asked for 10 but we had only 3 in the buffer, it will return 7 representing the remaining demand
            // We actually don't care about that number, as once we buffer more items they will be flushed right away, so simply ignore it
            _ = buffer?.buffer(value: .init(sender: sender, type: .txtRecords(NetService.dictionary(fromTXTRecord: data))))
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            guard let addresses = sender.addresses else { return }
            // This will either buffer or flush the items right away.
            // If subscriber asked for 10 but we had only 3 in the buffer, it will return 7 representing the remaining demand
            // We actually don't care about that number, as once we buffer more items they will be flushed right away, so simply ignore it
            _ = buffer?.buffer(value: .init(sender: sender, type: .resolvedAddresses(addresses)))
        }

        func netServiceDidStop(_ sender: NetService) {
            buffer?.complete(completion: .finished)
        }

        func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
            buffer?.complete(completion: .failure(.didNotPublish(errorDict)))
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
            buffer?.complete(completion: .failure(.didNotResolve(errorDict)))
        }

        private func start() {
            service.startMonitoring()
        }

        private func stop() {
            service.stopMonitoring()
        }
    }
}

extension BonjourService {
    public func erase() -> BonjourServiceType {
        .init(bonjourService: self)
    }
}

// MARK: - Model
extension BonjourService {
    public struct Event {
        public let sender: NetService
        public let type: EventType

        public init(sender: NetService, type: EventType) {
            self.sender = sender
            self.type = type
        }
    }

    public enum EventType {
        case txtRecords([String: Data])
        case resolvedAddresses([Data])
    }

    public enum BonjourServiceError: Error {
        case didNotPublish([String: NSNumber])
        case didNotResolve([String: NSNumber])
    }
}
