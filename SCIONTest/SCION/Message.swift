//
//  Message.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 10.05.21.
//

import Foundation

/// A UDP datagram sent with SCION
struct SCIONMessage {
    /// The received payload
    let contents: Data
    
    /// Source of the message
    let source: SCIONAddress
    
    /// Mirrored path that the message took. Without metadata. Uses `SCIONPathSource` in order to only initialize a path when actually needed
    let replyPath: SCIONPathSource?
}
