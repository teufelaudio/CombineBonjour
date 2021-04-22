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

extension NWBrowser {
    public var publisher: NWBrowserPublisher {
        .init(browser: self)
    }
}

public struct NWBrowserPublisher {
    private let browser: NWBrowser

    public init(browser: NWBrowser) {
        self.browser = browser
    }

    public init(
        serviceType: String,
        domain: String?,
        params: NWParameters = .tcp
    ) {
        self.browser = NWBrowser(
            for: NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: serviceType,
                domain: domain
            ),
            using: params
        )
    }
}

extension NWBrowserPublisher: Publisher {
    public typealias Output = Event
    public typealias Failure = NWBrowserError

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        let subscription = Subscription(
            subscriber: subscriber,
            browser: browser
        )
        subscriber.receive(subscription: subscription)
    }
}

extension NWBrowserPublisher {
    private class Subscription<SubscriberType: Subscriber>: Combine.Subscription
    where SubscriberType.Input == Output, SubscriberType.Failure == Failure {
        private var buffer: DemandBuffer<SubscriberType>?
        private let browser: NWBrowser

        // We need a lock to update the state machine of this Subscription
        private let lock = NSRecursiveLock()
        // The state machine here is only a boolean checking if the bonjour is browsing or not
        // If should start browsing when there's demand for the first time (not necessarily on subscription)
        // Only demand starts the side-effect, so we have to be very lazy and postpone the side-effects as much as possible
        private var started: Bool = false

        init(subscriber: SubscriberType, browser: NWBrowser) {
            self.browser = browser
            self.buffer = DemandBuffer(subscriber: subscriber)

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
                    guard let strongSelf = self else { return }

                    switch change {
                    case .identical:
                        break
                    case let .added(result):
                        strongSelf.serviceAdded(result: result)
                    case let .removed(result):
                        strongSelf.serviceRemoved(result: result)
                    case .changed(old: let old, new: let new, flags: let flags):
                        strongSelf.serviceChanged(from: old, to: new, with: flags)
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

        private func serviceAdded(result: NWBrowser.Result) {
            // we now can emit that we've found a service, but we may need to resolve it
            _ = buffer?.buffer(value: .didFind(endpoint: result.endpoint, txt: result.metadata.txt))
        }

        private func serviceRemoved(result: NWBrowser.Result) {
            _ = buffer?.buffer(value: .didRemove(endpoint: result.endpoint, txt: result.metadata.txt))
        }

        private func serviceChanged(from old: NWBrowser.Result, to new: NWBrowser.Result, with flags: NWBrowser.Result.Change.Flags) {
            _ = buffer?.buffer(value: .didUpdate(oldEndpoint: old.endpoint, newEndpoint: new.endpoint, txt: new.metadata.txt, flags: flags))
        }

        private func handleError(error: NWError) {
            if case let .dns(dnsServiceErrorType) = error, dnsServiceErrorType == kDNSServiceErr_PolicyDenied {
                _ = buffer?.complete(completion: .failure(.bonjourPermissionDenied))
            } else {
                _ = buffer?.complete(completion: .failure(.didNotSearch(error: error)))
            }
        }
    }
}

// MARK: - Model
extension NWBrowserPublisher {
    public enum Event {
        /// A service was found.
        case didFind(endpoint: NWEndpoint, txt: [String: String]?)

        /// A previously discovered service is no longer published.
        case didRemove(endpoint: NWEndpoint, txt: [String: String]?)

        /// A previously discovered service changed. Usually this means, it was discovered or removed on another network interface. See flags.
        case didUpdate(oldEndpoint: NWEndpoint, newEndpoint: NWEndpoint, txt: [String: String]?, flags: NWBrowser.Result.Change.Flags)
    }

    public enum NWBrowserError: Error {
        /// The user needs to grant the app permissions to discover devices in the network.
        case bonjourPermissionDenied
        /// Any other error that can happen during discovery
        case didNotSearch(error: NWError)
    }
}
