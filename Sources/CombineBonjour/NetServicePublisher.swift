//
//  NetServicePublisher.swift
//  FoundationExtensions
//
//  Created by Luiz Barbosa on 06.03.20.
//  Copyright © 2020 Lautsprecher Teufel GmbH. All rights reserved.
//

import Combine
import Foundation

extension NetService {
    public func publisher(monitorDevice: Bool, timeout: TimeInterval = 5.0) -> NetServicePublisher {
        .init(netService: self, timeout: timeout, monitorDevice: monitorDevice)
    }
}

public struct NetServicePublisher {
    private let netService: NetService
    private let timeout: TimeInterval
    private let monitorDevice: Bool

    public init(netService: NetService, timeout: TimeInterval, monitorDevice: Bool) {
        self.netService = netService
        self.timeout = timeout
        self.monitorDevice = monitorDevice
    }

    public init(name: String, domain: String, type: String, timeout: TimeInterval, monitorDevice: Bool) {
        self.netService = .init(domain: domain, type: type, name: name)
        self.timeout = timeout
        self.monitorDevice = monitorDevice
    }
}

extension NetServicePublisher: Publisher {
    public typealias Output = Event
    public typealias Failure = NetServiceError

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        let subscription = Subscription(
            subscriber: subscriber,
            netService: netService,
            timeout: timeout,
            monitorDevice: monitorDevice
        )
        subscriber.receive(subscription: subscription)
    }
}

extension NetServicePublisher {
    private class Subscription<SubscriberType: Subscriber>: NSObject, Combine.Subscription, NetServiceDelegate
    where SubscriberType.Input == Output, SubscriberType.Failure == Failure {
        private var buffer: DemandBuffer<SubscriberType>?
        private let netService: NetService
        private let timeout: TimeInterval
        private let monitorDevice: Bool

        // We need a lock to update the state machine of this Subscription
        private let lock = NSRecursiveLock()
        // The state machine here is only a boolean checking if the bonjour is browsing or not
        // If should start browsing when there's demand for the first time (not necessarily on subscription)
        // Only demand starts the side-effect, so we have to be very lazy and postpone the side-effects as much as possible
        private var started: Bool = false

        init(subscriber: SubscriberType, netService: NetService, timeout: TimeInterval, monitorDevice: Bool) {
            self.netService = netService
            self.buffer = DemandBuffer(subscriber: subscriber)
            self.timeout = timeout
            self.monitorDevice = monitorDevice
            super.init()

            netService.delegate = self
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
            stop()
        }

        func netServiceWillPublish(_ sender: NetService) {
            _ = buffer?.buffer(value: .init(netService: sender, type: .willPublish))
        }

        func netServiceDidPublish(_ sender: NetService) {
            _ = buffer?.buffer(value: .init(netService: sender, type: .didPublish))
        }

        func netServiceWillResolve(_ sender: NetService) {
            _ = buffer?.buffer(value: .init(netService: sender, type: .willResolve))
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            let addresses = sender.addresses ?? []
            _ = buffer?.buffer(value: .init(netService: sender, type: .didResolveAddress(addresses)))
        }

        func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
            _ = buffer?.buffer(value: .init(netService: sender, type: .didUpdateTXTRecord(txtRecord: NetService.dictionary(fromTXTRecord: data))))
        }

        func netService(_ sender: NetService, didAcceptConnectionWith inputStream: InputStream, outputStream: OutputStream) {
            _ = buffer?.buffer(value: .init(netService: sender, type: .didAcceptConnectionWith(inputStream: inputStream, outputStream: outputStream)))
        }

        func netServiceDidStop(_ sender: NetService) {
            buffer?.complete(completion: .finished)
        }

        func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
            buffer?.complete(completion: .failure(.didNotPublish(netService: sender, errorDict: errorDict)))
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
            guard let errorDomain = errorDict["NSNetServicesErrorDomain"]?.intValue,
                  let errorCode = errorDict["NSNetServicesErrorCode"]?.intValue else { return }

            if errorCode == NetService.ErrorCode.timeoutError.rawValue {
                buffer?.complete(completion: .failure(.netServiceTimeout))
                return
            }

            buffer?.complete(completion: .failure(.didNotResolve(netService: sender, errorDict: errorDict, errorDomain: errorDomain, errorCode: errorCode)))
        }

        private func start() {
            if monitorDevice {
                netService.startMonitoring()
            }
            netService.resolve(withTimeout: timeout)
        }

        private func stop() {
            if monitorDevice {
                netService.stopMonitoring()
            }
            lock.lock()
            buffer = nil
            started = false
            lock.unlock()
        }
    }
}

// MARK: - Model
extension NetServicePublisher {
    public struct Event: Equatable {
        public let netService: NetService
        public let type: EventType

        public init(netService: NetService, type: EventType) {
            self.netService = netService
            self.type = type
        }
    }

    public enum EventType: Equatable {
        /// Sent to the NSNetService instance's delegate prior to advertising the service on the network.
        /// If for some reason the service cannot be published, the delegate will not receive this message, and an error will be delivered to the
        /// delegate via the delegate's -netService:didNotPublish: method.
        case willPublish

        /// Sent to the NSNetService instance's delegate when the publication of the instance is complete and successful.
        case didPublish

        /// Sent to the NSNetService instance's delegate prior to resolving a service on the network. If for some reason the resolution cannot occur,
        /// the delegate will not receive this message, and an error will be delivered to the delegate via the delegate's
        /// -netService:didNotResolve: method.
        case willResolve

        /// Sent to the NSNetService instance's delegate when one or more addresses have been resolved for an NSNetService instance.
        /// Some NSNetService methods will return different results before and after a successful resolution.
        /// An NSNetService instance may get resolved more than once; truly robust clients may wish to resolve again after an error,
        /// or to resolve more than once.
        case didResolveAddress([Data])

        /// Sent to the NSNetService instance's delegate when the instance is being monitored and the instance's TXT record has been updated.
        /// The new record is contained in the data parameter.
        case didUpdateTXTRecord(txtRecord: [String: Data])

        /// Sent to a published NSNetService instance's delegate when a new connection is
        /// received. Before you can communicate with the connecting client, you must -open
        /// and schedule the streams. To reject a connection, just -open both streams and
        /// then immediately -close them.

        /// To enable TLS on the stream, set the various TLS settings using
        /// kCFStreamPropertySSLSettings before calling -open. You must also specify
        /// kCFBooleanTrue for kCFStreamSSLIsServer in the settings dictionary along with
        /// a valid SecIdentityRef as the first entry of kCFStreamSSLCertificates.
        case didAcceptConnectionWith(inputStream: InputStream, outputStream: OutputStream)
    }

    public enum NetServiceError: Error {
        /// Sent to the NSNetService instance's delegate when an error in publishing the instance occurs.
        /// The error dictionary will contain two key/value pairs representing the error domain and code (see the NSNetServicesError enumeration
        /// above for error code constants). It is possible for an error to occur after a successful publication.
        case didNotPublish(netService: NetService, errorDict: [String : NSNumber])

        /// Sent to the NSNetService instance's delegate when an error in resolving the instance occurs.
        /// The error dictionary will contain two key/value pairs representing the error domain and code
        /// (see the NSNetServicesError enumeration above for error code constants).
        case didNotResolve(netService: NetService, errorDict: [String : NSNumber], errorDomain: Int, errorCode: Int)

        /// The NetService search didn't resolve in the provided time
        case netServiceTimeout
    }
}
