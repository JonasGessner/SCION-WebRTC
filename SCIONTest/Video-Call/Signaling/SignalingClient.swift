//
//  SignalClient.swift
//  WebRTC
//
//  Created by Stasel on 20/05/2018.
//  Copyright © 2018 Stasel. All rights reserved.
//
// https://github.com/stasel/WebRTC-iOS

import Foundation
import WebRTC

protocol SignalClientDelegate: AnyObject {
    func signalClientDidConnect(_ signalClient: SignalingClient)
    func signalClientDidDisconnect(_ signalClient: SignalingClient)
    func signalClient(_ signalClient: SignalingClient, didReceiveRemoteSdp sdp: RTCSessionDescription, serverInfo: RelayServerInfo?)
    func signalClient(_ signalClient: SignalingClient, didReceiveCandidate candidate: RTCIceCandidate)
    func signalClient(didReceiveHangUpSignal signalClient: SignalingClient)
}

final class SignalingClient {
    
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let webSocket: WebSocketProvider
    weak var delegate: SignalClientDelegate?
    
    init(webSocket: WebSocketProvider) {
        self.webSocket = webSocket
        
        HellPreprocessor
            .newLocalPathsPublisher
            .map({ ($0, $1.sorted(by: { $0.canonicalFingerprintShort < $1.canonicalFingerprintShort })) })
            .removeDuplicates(by: {
                $0.0 == $1.0 && $0.1 == $1.1
            })
            .map({ $0.1 })
            .autoDisposableSink(receiveValue:  { paths in
                let p: [SCIONPath]
                if testCase == .videoMetricsReport {
                    p = paths.filter({ $0.canonicalFingerprintShort == "126e7" })
                }
                else {
                    p = paths
                }
                
                let message = Message.paths(p.map({ $0.canonicalFingerprintShort }))
                
                let dataMessage = try! self.encoder.encode(message)
                
                self.webSocket.send(data: dataMessage)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.webSocket.send(data: dataMessage)
                }
            })
    }
    
    func connect() {
        self.webSocket.delegate = self
        self.webSocket.connect()
    }
    
    func send(serverInfo: RelayServerInfo? = nil, sdp rtcSdp: RTCSessionDescription) throws {
        let message = Message.sdp(serverInfo, SessionDescription(from: rtcSdp))
        let dataMessage = try self.encoder.encode(message)
        
        self.webSocket.send(data: dataMessage)
    }
    
    func send(candidate rtcIceCandidate: RTCIceCandidate) throws {
        let message = Message.candidate(IceCandidate(from: rtcIceCandidate))
        let dataMessage = try self.encoder.encode(message)
        
        self.webSocket.send(data: dataMessage)
    }
    
    func sendHangUp() throws {
        let message = Message.hangUp
        let dataMessage = try self.encoder.encode(message)
        
        self.webSocket.send(data: dataMessage)
    }
}


extension SignalingClient: WebSocketProviderDelegate {
    func webSocketDidConnect(_ webSocket: WebSocketProvider) {
        self.delegate?.signalClientDidConnect(self)
    }
    
    func webSocketDidDisconnect(_ webSocket: WebSocketProvider) {
        self.delegate?.signalClientDidDisconnect(self)
        
        // try to reconnect every two seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            debugPrint("Trying to reconnect to signaling server...")
            self.webSocket.connect()
        }
    }
    
    func webSocket(_ webSocket: WebSocketProvider, didReceiveData data: Data) {
        let message: Message
        do {
            message = try self.decoder.decode(Message.self, from: data)
        }
        catch {
            debugPrint("Warning: Could not decode incoming message: \(error)")
            return
        }
        
        switch message {
        case .candidate(let iceCandidate):
            self.delegate?.signalClient(self, didReceiveCandidate: iceCandidate.rtcIceCandidate)
        case .sdp(let serverInfo, let sessionDescription):
            self.delegate?.signalClient(self, didReceiveRemoteSdp: sessionDescription.rtcSessionDescription, serverInfo: serverInfo)
        case .hangUp:
            self.delegate?.signalClient(didReceiveHangUpSignal: self)
        case .paths(let paths):
            HellPreprocessor.pathsOther = paths
//            let candidate = RTCIceCandidate(sdp: "candidate:453802058 1 udp 41885439 158.69.221.198 59273 typ relay raddr 0.0.0.0 rport 0 generation 0 ufrag 0Fcp network-id 1 network-cost 10", sdpMLineIndex: 0, sdpMid: "0")
//            
//            //                    self.webRTCClient.set(remoteCandidate: candidate)
//            self.send(candidate: candidate)
        }

    }
}
