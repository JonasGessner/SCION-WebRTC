//
//  Address.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 10.05.21.
//

import Foundation
import SCIONDarwin

/// Opaque represenation of a SCION UDP address
struct SCIONAddress: CustomStringConvertible {
    let appnetAddress: IosUDPAddress
    
    internal init(appnetAddress: IosUDPAddress) {
        self.appnetAddress = appnetAddress
        description = appnetAddress.string()
    }
    
    let description: String
    
    func isInForeignAS(to other: SCIONAddress) -> Bool {
        return appnetAddress.isForeign(to: other.appnetAddress)
    }
}

extension SCIONAddress: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let address = try container.decode(String.self, forKey: .address)
        try self.init(string: address)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .address)
    }
    
    enum CodingKeys: String, CodingKey {
        case address
    }
}

extension SCIONAddress: Equatable {
    static func == (lhs: SCIONAddress, rhs: SCIONAddress) -> Bool {
        return lhs.description == rhs.description
    }
}

extension SCIONAddress: Hashable {
    func hash(into hasher: inout Hasher) {
        description.hash(into: &hasher)
    }
}

extension SCIONAddress {
    init(string: String) throws {
        var error: NSError?
        guard let address = IosUDPAddressMake(string, &error) else {
            throw error ?? SCIONError.general
        }
        self.init(appnetAddress: address)
    }
}
