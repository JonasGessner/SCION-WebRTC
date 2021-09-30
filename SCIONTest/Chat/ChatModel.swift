//
//  ChatModel.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 13.04.21.
//

import Foundation
import Combine

let bandwidthTestMarker = "__bandwidth".data(using: .utf8)!

struct ChatMessage {
    /// Content of the message.
    let rawContent: Data
    let content: String
    /// The address of the peer with whom this message was exchanged.
    let peer: SCIONAddress
    /// Path that was taken by the message. For sent messages is it the path to the other peer. For received it it the path taken from the peer.
    let path: SCIONPath?
    /// Whether the message was sent or received from the local peer.
    let sent: Bool
    
    let id = UUID()
}

final class ChatConnection: ObservableObject {
    let connection: SCIONUDPConnection
    
    @Published private(set) var chat = [ChatMessage]()
    @Published private(set) var lossTestSent = 0
    @Published private(set) var lossTestAcksReceived = 0
    @Published private(set) var lossTestAcksSent = 0
    
    @Published private(set) var bandwidthTestsSent = 0
    @Published private(set) var bandwidthTestsReceived = 0
    
    @Published private(set) var bandwidthSent = 0
    @Published private(set) var bandwidthReceived = 0
    
    private var sub: AnyCancellable?
    
    init(connection: SCIONUDPConnection) {
        self.connection = connection
        
        sub = connection.listen()
            .sink { [weak self] message in
                guard let self = self else { return }
                
                if message.data.starts(with: bandwidthTestMarker) {
                    DispatchQueue.main.async {
                        self.bandwidthTestsReceived += 1
                        self.bandwidthReceived += message.data.count
                    }
                    return
                }
                
                let str = String(data: message.data, encoding: .utf8)!
                if str == "_____________________loss_test" {
                    try! connection.send(data: "_____________________loss_test_ok".data(using: .utf8)!, path: message.replyPath)
                    DispatchQueue.main.async {
                        self.lossTestAcksSent += 1
                    }
                }
                else if str == "_____________________loss_test_ok" {
                    DispatchQueue.main.async {
                        self.lossTestAcksReceived += 1
                    }
                }
                else {
                    let chatMessage = ChatMessage(rawContent: message.data, content: str, peer: message.source, path: message.replyPath?.path, sent: false)
                    assert(message.source == connection.remoteAddress)
                    DispatchQueue.main.async {
                        self.chat.append(chatMessage)
                    }
                }
            }
    }
    
    func sendLossTest() {
        try! connection.send(data: "_____________________loss_test".data(using: .utf8)!)
        lossTestSent += 1
    }
    
    func resetTestStats() {
        lossTestSent = 0
        lossTestAcksReceived = 0
        lossTestAcksSent = 0
        
        bandwidthTestsSent = 0
        bandwidthSent = 0
        
        bandwidthTestsReceived = 0
        bandwidthReceived = 0
    }
    
    func sendBandwithPacket(index: UInt64, payloadSize: Int) {
        let encoded = bandwidthTestMarker + index.encodeBinary()
        
        let padding = Data(count: payloadSize - encoded.count)
        let payload = encoded + padding
        
        do {
            try connection.send(data: payload)

            DispatchQueue.main.async {
                self.bandwidthTestsSent += 1
                self.bandwidthSent += payloadSize
            }
        }
        catch {
            print("Sending bandwidth test packet failed: \(error)")
        }
    }
    
    func send(_ str: String) throws {
        let data = str.data(using: .utf8)!
        
        let (path, _) = try connection.send(data: data, wantUsedPath: true)

        let chatMessage = ChatMessage(rawContent: data, content: str, peer: connection.remoteAddress, path: path?.path, sent: true)

        chat.append(chatMessage)
    }
}

final class ChatServerModel: ObservableObject {
    let server: SCIONUDPListener
    @Published private(set) var clientConnections = [ChatConnection]()
    
    private var sub: AnyCancellable?
    
    init(server: SCIONUDPListener) {
        self.server = server
        
        sub = server.accept()
            .map({ ChatConnection(connection: $0) })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.clientConnections.append($0)
            }
    }
}

final class ChatModel: ObservableObject {
    @Published private(set) var servers = [ChatServerModel]()
    @Published private(set) var clients = [ChatConnection]()
    
    func add(client: SCIONUDPConnection) {
        clients.append(ChatConnection(connection: client))
    }
    
    func add(server: SCIONUDPListener) {
        servers.append(ChatServerModel(server: server))
    }
}
