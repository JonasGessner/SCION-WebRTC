//
//  ReceiveExtensions.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 10.05.21.
//

import Foundation
import Combine

let probeRequest = "0x69".data(using: .utf8)!
let probeResponse = "0x420".data(using: .utf8)!
let penaltyNotificationHeader = "69".data(using: .utf8)!

/// A receive extension is an adapter that gets fed all receives messages before they are broadcasted further downstream in a connection listener. Extensions handle messages after active path processors do. The extension can mutate the incoming message or drop it completely. It can fully interact with its parent connection and send traffic.
protocol SCIONConnectionReceiveExtension {
    func handleReceive(of message: SCIONMessage, on connection: SCIONUDPConnection) -> SCIONMessage?
}

struct SequentialReceiveExtension: SCIONConnectionReceiveExtension {
    // NOTE: Can't modify message, only set to nil.
    let receivers: [SCIONConnectionReceiveExtension]
    
    func handleReceive(of message: SCIONMessage, on connection: SCIONUDPConnection) -> SCIONMessage? {
        return receivers.reduce(message as SCIONMessage?, {
            let val = $1.handleReceive(of: message, on: connection)
            return $0 == nil ? $0 : val
        })
    }
}

struct LatencyProbingReceiveExtension: SCIONConnectionReceiveExtension {
    // Mirrors the probe back via the incoming path to get an accurate RTT time measurement
    private func respondProbe(data: Data, from message: SCIONMessage, on connection: SCIONUDPConnection) throws {
        _ = try connection.send(data: data, path: message.replyPath)
    }
    
    func handleReceive(of message: SCIONMessage, on connection: SCIONUDPConnection) -> SCIONMessage? {
        let data = message.contents
        
        if data.starts(with: probeRequest) {
            do {
//                print("Got probe \(message.replyPath!.path.canonicalFingerprintShort)")
                let response = probeResponse + data[probeRequest.count...]
                try respondProbe(data: response, from: message, on: connection)
            }
            catch {
                print("Probe response error \(error)")
            }
            return nil
        }
        else if data.starts(with: probeResponse) {
            // Probe response received but path processor on the connection is no longer the latency probing path processor. Drop the message here
            return nil
        }
        
        return message
    }
}
