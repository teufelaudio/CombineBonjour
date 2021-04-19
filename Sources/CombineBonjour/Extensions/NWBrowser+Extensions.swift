//
//  NWBrowser+Extensions.swift
//  CombineBonjour
//
//  Created by Luiz Rodrigo Martins Barbosa on 15.04.21.
//  Copyright © 2021 Lautsprecher Teufel GmbH. All rights reserved.
//

import Network
import Foundation

extension NWBrowser.Result.Metadata {
    public var txt: [String: String]? {
        switch self {
        case .none:
            return nil
        case let .bonjour(txtRecords):
            return txtRecords.dictionary
        @unknown default:
            fatalError("NWBrowser.Result.Metadata case not implemented: \(self)")
        }
    }
}
