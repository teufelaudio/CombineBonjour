//
//  NetService+Extensions.swift
//  CombineBonjour
//
//  Created by Luiz Rodrigo Martins Barbosa on 15.04.21.
//  Copyright © 2021 Lautsprecher Teufel GmbH. All rights reserved.
//

import Foundation

extension NetService {
    public func parsedAddresses() -> [String] {
        guard let addresses = self.addresses else {
            return []
        }

        return addresses.compactMap {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            $0.withUnsafeBytes { ptr in
                guard let sockaddr_ptr = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return /* ignoe error */ }
                let sockaddr = sockaddr_ptr.pointee
                guard getnameinfo(
                    sockaddr_ptr,
                    socklen_t(sockaddr.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0
                else { return /* ignore error */ }
            }
            return String(cString: hostname)
        }
    }
}
