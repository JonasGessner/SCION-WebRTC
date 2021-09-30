//
//  SessionDescription.swift
//  WebRTC-Demo
//
//  Created by Stasel on 20/02/2019.
//  Copyright © 2019 Stasel. All rights reserved.
//
// https://github.com/stasel/WebRTC-iOS

import Foundation
import WebRTC
import Network

enum RelayServerProtocol: Int, Codable {
    case scion
    case udp
}

enum ChannelType: String, Codable, Equatable, Hashable, CaseIterable {
    case audio
    case video
    case data
}

struct RelayEndpoint {
    let channelType: ChannelType
    let port: UInt16
}

extension RelayEndpoint: Codable {}

/// Information about local relay, not to be confused with TURN relay server.
struct RelayServerInfo: Codable {
    let serverAddress: String
    let networkProtocol: RelayServerProtocol
    let endpoints: [RelayEndpoint]
}

extension RelayServerInfo {
    init(from server: SCIONVideoCallRelayListener) throws {
        // This is a ISD-AS-IP-Port address
        guard let serverAddress = server.channels.first?.1.localAddress?.description else {
            fatalError() // TODO error handling
        }
        
        // Remove the port number
        let addressWithoutPort = serverAddress.components(separatedBy: ":").dropLast().joined(separator: ":")
        self.serverAddress = addressWithoutPort
        self.endpoints = server.channels.map { RelayEndpoint(channelType: $0.0, port: $0.1.port) }
        
        self.networkProtocol = .scion
    }
    
    init(from server: UDPVideoCallRelayListener) throws {
        guard
            let ipAddress = getWiFiIPAddress()
        else {
            // TODO: error handling
            fatalError()
        }
        
        // Remove the port number
        self.serverAddress = ipAddress
        self.endpoints = server.channels.map { RelayEndpoint(channelType: $0.0, port: $0.1.port!.rawValue) }

        self.networkProtocol = .udp
    }
}

/// This enum is a swift wrapper over `RTCSdpType` for easy encode and decode
enum SdpType: String, Codable {
    case offer, prAnswer, answer, rollback
    
    var rtcSdpType: RTCSdpType {
        switch self {
        case .offer:    return .offer
        case .answer:   return .answer
        case .prAnswer: return .prAnswer
        case .rollback: return .rollback
        }
    }
}

/// This struct is a swift wrapper over `RTCSessionDescription` for easy encode and decode
struct SessionDescription: Codable {
    let sdp: String
    let type: SdpType
    
    init(from rtcSessionDescription: RTCSessionDescription) {
        self.sdp = rtcSessionDescription.sdp
        
        switch rtcSessionDescription.type {
        case .offer:    self.type = .offer
        case .prAnswer: self.type = .prAnswer
        case .answer:   self.type = .answer
        case .rollback: self.type = .rollback
        @unknown default:
            fatalError("Unknown RTCSessionDescription type: \(rtcSessionDescription.type.rawValue)")
        }
    }
    
    var rtcSessionDescription: RTCSessionDescription {
        return RTCSessionDescription(type: self.type.rtcSdpType, sdp: self.sdp)
    }
}
