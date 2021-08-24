// Copyright © 2021 Lautsprecher Teufel GmbH. All rights reserved.

import Foundation

public struct ServiceDescription {
    public let serviceName: String
    public let domain: String
    public let type: String

    public init(serviceName: String, type: String, domain: String) {
        self.serviceName = serviceName
        self.type = type
        self.domain = domain
    }
}
