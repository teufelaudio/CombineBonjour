//
//  NWEndpointPublisher.swift
//  CombineBonjour
//
//  Created by Thomas Mellenthin on 22.04.21.
//  Copyright © 2021 Lautsprecher Teufel GmbH. All rights reserved.
//

import Foundation

public struct ServiceDescription {
    public let serviceName: String
    public let domain: String

    public init(serviceName: String, domain: String) {
        self.serviceName = serviceName
        self.domain = domain
    }
}
