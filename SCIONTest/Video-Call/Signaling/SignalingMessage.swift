//
//  Message.swift
//  WebRTC-Demo
//
//  Created by Stasel on 20/02/2019.
//  Copyright © 2019 Stasel. All rights reserved.
//
// https://github.com/stasel/WebRTC-iOS

import Foundation

enum Message {
    case sdp(RelayServerInfo?, SessionDescription)
    case candidate(IceCandidate)
    case paths([String])
    case hangUp
}

extension Message: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .sdp:
            self = .sdp(try container.decodeIfPresent(RelayServerInfo.self, forKey: .payload1), try container.decode(SessionDescription.self, forKey: .payload2))
        case .candidate:
            self = .candidate(try container.decode(IceCandidate.self, forKey: .payload1))
        case .hangUp:
            self = .hangUp
        case .paths:
            self = .paths(try container.decode([String].self, forKey: .payload1))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sdp(let relay, let sessionDescription):
            try container.encodeIfPresent(relay, forKey: .payload1)
            try container.encode(sessionDescription, forKey: .payload2)
            try container.encode(MessageType.sdp, forKey: .type)
        case .candidate(let iceCandidate):
            try container.encode(iceCandidate, forKey: .payload1)
            try container.encode(MessageType.candidate, forKey: .type)
        case .hangUp:
            try container.encode(MessageType.hangUp, forKey: .type)
        case .paths(let paths):
            try container.encode(MessageType.paths, forKey: .type)
            try container.encode(paths, forKey: .payload1)
        }
    }
    
    enum DecodeError: Error {
        case unknownType
    }
    
    enum MessageType: Int, Codable {
        case sdp
        case candidate
        case hangUp
        case paths
    }
    
    enum CodingKeys: String, CodingKey {
        case type, payload1, payload2
    }
}
