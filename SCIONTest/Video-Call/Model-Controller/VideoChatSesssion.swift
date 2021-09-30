//
//  VideoChatSesssion.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 29.03.21.
//

import Foundation
import SwiftUI
import WebRTC
import Combine
import Network

struct StatisticsReportAudio {
    let outboundRTP: AudioOutboundRTPStats
    let transport: TransportWebRTCStats
    
    let senderTrack: TrackSenderAudioRTCStats
    let receiverTrack: TrackReceiverAudioRTCStats
    
    let remoteInboundRTP: RemoteInboundRTPStats
}

struct StatisticsReportVideo {
    let outboundRTP: VideoOutboundRTPStats
    let transport: TransportWebRTCStats
    
    let senderTrack: TrackSenderVideoRTCStats
    let receiverTrack: TrackReceiverVideoRTCStats
    
    let remoteInboundRTP: RemoteInboundRTPStats
    
    let inboundRTP: VideoInbountRTPStats
}

struct StatisticsReport {
    let audio: StatisticsReportAudio
    let video: StatisticsReportVideo
}

/// This class manages an entire call: SIgnaling, the WebRTC session, statistics reporting.
final class VideoChatSession: ObservableObject {
    enum CallState: Equatable {
        case idle // no call
        case requestedOutgoing(WebRTCClient)
        case incomingRequest(WebRTCClient)
        case ongoing(Bool, WebRTCClient, RTCIceConnectionState)
        
        var client: WebRTCClient? {
            switch self {
            case .idle:
                return nil
            case .incomingRequest(let c):
                return c
            case .ongoing(_, let c, _):
                return c
            case .requestedOutgoing(let c):
                return c
            }
        }
        
        var isCallInitiator: Bool {
            switch self {
            case .ongoing(let i, _, _):
                return i
            case .requestedOutgoing(_):
                return true
            default:
                return false
            }
        }
        
        var isCallSetupPhase: Bool {
            switch self {
            case .idle:
                return false
            case .incomingRequest(_):
                return true
            case .ongoing(_, _, _):
                return false
            case .requestedOutgoing(_):
                return true
            }
        }
    }
    
    private let stallObserverQueue = DispatchQueue(label: "stall observer", qos: .utility, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    static let shared = VideoChatSession()
    
    private let signalingClient = SignalingClient(webSocket: NativeWebSocket(url: defaultSignalingServerUrl))

    @Published private(set) var hasLocalSdp = false
    @Published private(set) var localCandidateCount = 0
    @Published private(set) var hasRemoteSdp = false
    @Published private(set) var remoteCandidateCount = 0
    
    // A new report is generated every second. If this is published it might cause a ton of unecessary redraws, hence use a dedicated publisher that doesn't call `objectWillChange`
    private(set) var latestReport: StatisticsReport?
    let reportPublisher = PassthroughSubject<StatisticsReport, Never>()
    
    @Published private(set) var callState = CallState.idle
    @Published private(set) var operationMode = WebRTCClient.OperationMode.relaySCION
    
    @Published private(set) var signalingConnected = false
    @Published var sendingAudio = true {
        didSet {
            if sendingAudio {
                callState.client?.unmuteAudio()
            }
            else {
                callState.client?.muteAudio()
            }
        }
    }
    @Published var sendingVideo = true {
        didSet {
            if sendingVideo {
                callState.client?.showVideo()
            }
            else {
                callState.client?.hideVideo()
            }
        }
    }
    
    private let statsQueue = DispatchQueue(label: "webrtc-stats", qos: .utility, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    
    private init() {
        signalingClient.delegate = self
        signalingClient.connect()
        // Make it so that the mac app always initates an automatic call. This only works when running the app on iOS on one device and macOS on the other!!
        if isCloud() && autoDialCall {
            offerCall()
        }

        if testCase.isVideoCallTest {
            NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "hangup__"), object: nil, queue: .main) { _ in
                self.hangUp()
            }
        }
    }
    
    private func stallObserverLoop<R: PacketTimingRelay>(_ channelType: ChannelType, _ index: Int, _ conn: SCIONUDPConnection, _ relay: R) where R.Connection == SCIONUDPConnection {
        guard useStallMonitor else { return }
        
        switch callState {
        case .ongoing(_, _, _):
            break
        default:
            return
        }
        if let date = relay.lastReceievePacketDate[index][0] {
            if Date().timeIntervalSince(date) > 0.1 {
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "relay-stall"), object: nil, userInfo: ["type": channelType])
            }
        }
        stallObserverQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.stallObserverLoop(channelType, index, conn, relay)
        }
    }
    
    func offerCall(numberOfVideoChannels: Int = 1, numberOfAudioChannels: Int = 1) {
        guard callState == .idle else {
            fatalError()
        }
        
        let client = WebRTCClient(iceServers: [], operationMode: operationMode)
        client.delegate = self
        client.startCaptureLocalVideo(renderer: nil)
        
        callState = .requestedOutgoing(client)
        
        client.offer { sdp in
            DispatchQueue.main.async {
                self.hasLocalSdp = true
                
                let serverInfo: RelayServerInfo?
                
                if self.operationMode == .normal {
                    serverInfo = nil
                }
                else {
                    do {
                        let adapter = try UDPVideoCallRelayListener(channelTypes: [.audio, .video], acceptPredicate: UDPVideoCallRelayListener.acceptLoopbackOnlyPredicate, parameters: UDPVideoCallRelayListener.localhostAdapterParameters)
                        self.relayAdapter = adapter
                        
                        switch self.operationMode {
                        case .normal:
                            serverInfo = nil
                            break
                            
                        case .relayUDP:
                            let server = try UDPVideoCallRelayListener(channelTypes: [.audio, .video], parameters: UDPVideoCallRelayListener.wifiRelayParameters)
                            serverInfo = try RelayServerInfo(from: server)
                            self.remoteRelay = .udp(.server(server))
                            
                            adapter.pipe(through: server)
                            server.pipe(through: adapter)
                            
                        case .relaySCION:
                            let channelTypes =
                                [ChannelType](repeating: .audio, count: numberOfAudioChannels + (testCase == .videoRedundantTransmissionReport ? 1 : 0)) +
                                [ChannelType](repeating: .video, count: numberOfVideoChannels + (testCase == .videoRedundantTransmissionReport ? 1 : 0)) +
                                []
                            
                            HellPreprocessor.instanceID = UUID()
                            
                            let server = try SCIONVideoCallRelayListener(channelTypes: channelTypes)
                            serverInfo = try RelayServerInfo(from: server)
                            self.remoteRelay = .scion(.server(server))
                            
                            adapter.pipe(through: server)
                            server.pipe(through: adapter) { [weak self] channelType, index, conn, _ in
                                self?.stallObserverQueue.asyncAfter(deadline: .now() + 5) {
                                    self?.stallObserverLoop(channelType, index, conn, server)
                                }
                            }
                        }
                    }
                    catch {
                        fatalError()
                        // TODO: Handle error!!
                    }
                }
                
                func sendSDP() {
                    print("Sending SDP")
                    do {
                        try self.signalingClient.send(serverInfo: serverInfo, sdp: sdp)
                    }
                    catch {
                        fatalError()
                        // TODO: Handle error!!
                    }
                }
                
                sendSDP()
                
                // Re-send SDP periodically until someone picks up
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                    if self.callState.isCallSetupPhase {
                        sendSDP()
                    }
                    else {
                        timer.invalidate()
                    }
                }
            }
        }
    }
    
    func answerCall() {
        guard case let .incomingRequest(client) = callState, hasRemoteSdp else {
            fatalError()
        }
        
        assert(!callState.isCallInitiator)
        callState = .ongoing(false, client, .new)
        assert(!callState.isCallInitiator)
        
        client.answer { (localSdp) in
            DispatchQueue.main.async {
                self.hasLocalSdp = true
                self.callDidBegin()
            }
            
            print("Sending SDP")
            try! self.signalingClient.send(sdp: localSdp)
        }
    }
    
    fileprivate var lastHangUpTime = Date.distantPast
    
    func hangUp(_ notifyPeer: Bool = true) {
        guard let client = callState.client else {
            print("There is no call to hang up")
            return
        }
        
        func doHangUp() {
            client.hangUp()
            relayAdapter?.close()
            relayAdapter = nil
            switch remoteRelay {
            case .scion(let ep):
                switch ep {
                case .client(let c):
                    c.close()
                case .server(let s):
                    s.close()
                }
            case .udp(let ep):
                switch ep {
                case .client(let c):
                    c.close()
                case .server(let s):
                    s.close()
                }
            default: break
            }
            remoteRelay = nil
            localCandidates = localCandidates.map({_ in nil })
            fakeRemoteCandidates = fakeRemoteCandidates.map({_ in nil })
            gatheringStats = false
            
            localCandidateCount = 0
            remoteCandidateCount = 0
            hasLocalSdp = false
            hasRemoteSdp = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.callState = .idle
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if isCloud() && autoDialCall {
                        self.offerCall()
                    }
                }
            }
        }
        
        lastHangUpTime = Date()
        
        if notifyPeer {
            do {
                try signalingClient.sendHangUp()
            
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    doHangUp()
                }
            }
            catch {
                print("Hanging up failed: \(error)")
            }
        }
        else {
            doHangUp()
        }
    }
    
    private func callDidBegin() {
        startGatheringStats()
    }
    
    /// Locally catches traffic coming from WebRTC
    private var relayAdapter: UDPVideoCallRelayListener?
    /// Used to forward/relay WebRTC traffic caught by `relayAdapter` to a remote host via custom transport
    @Published private(set) var remoteRelay: AnyRelay?
    
    private var localCandidates: [RTCIceCandidate?] = [nil, nil] // [nil, nil, nil]
    private var fakeRemoteCandidates: [RTCIceCandidate?] = [nil, nil] //[nil, nil, nil]
    
    private var gatheringStats = false
}

extension VideoChatSession: SignalClientDelegate {
    func signalClient(didReceiveHangUpSignal signalClient: SignalingClient) {
        DispatchQueue.main.async {
            self.hangUp(false)
        }
    }
    
    func signalClientDidConnect(_ signalClient: SignalingClient) {
        DispatchQueue.main.async {
            self.signalingConnected = true
        }
    }
    
    func signalClientDidDisconnect(_ signalClient: SignalingClient) {
        DispatchQueue.main.async {
            self.signalingConnected = false
        }
    }
    
    func signalClient(_ signalClient: SignalingClient, didReceiveRemoteSdp sdp: RTCSessionDescription, serverInfo: RelayServerInfo?) {
        guard Date().timeIntervalSince(lastHangUpTime) > 2 else { return }
        
        DispatchQueue.main.async {
            let client: WebRTCClient
            if case let .requestedOutgoing(c) = self.callState {
                print("Got remote SDP")
                assert(self.callState.isCallInitiator)
                assert(serverInfo == nil)
                client = c
                self.hasRemoteSdp = true
                self.callState = .ongoing(true, client, .new)
                self.callDidBegin()
                assert(self.callState.isCallInitiator)
            }
            else if self.callState == .idle {
                print("Got remote SDP")
                assert(!self.callState.isCallInitiator)
                
                // Call initiator receives no server info, only call recipient receives server info
                if let serverInfo = serverInfo {
                    do {
                        let adapter = try UDPVideoCallRelayListener(channelTypes: [.audio, .video], acceptPredicate: UDPVideoCallRelayListener.acceptLoopbackOnlyPredicate, parameters: UDPVideoCallRelayListener.localhostAdapterParameters)
                        self.relayAdapter = adapter
                        
                        switch serverInfo.networkProtocol {
                        case .udp:
                            let relayClient = try UDPVideoCallRelayClient(serverInfo: serverInfo)
                            self.remoteRelay = .udp(.client(relayClient))
                            self.operationMode = .relayUDP
                            adapter.pipe(through: relayClient)
                            relayClient.pipe(through: adapter)
                            
                        case .scion:
                            HellPreprocessor.instanceID = UUID()
                            
                            let relayClient = try SCIONVideoCallRelayClient(serverInfo: serverInfo)
                            self.remoteRelay = .scion(.client(relayClient))
                            self.operationMode = .relaySCION
                            
                            // Send a discadable message on each channel so that the server immediately has a handle to this connection and starts querying paths ASAP.
                            relayClient.channels.map({ $0.1 }).forEach({
                                do {
                                    _ = try $0.send(data: Data([69, 42, 0]))
                                }
                                catch {
                                    fatalError(error.localizedDescription)
                                }
                            })
                            
                            adapter.pipe(through: relayClient)
                            relayClient.pipe(through: adapter) { [weak self] channelType, index, conn, _ in
                                self?.stallObserverQueue.asyncAfter(deadline: .now() + 5) {
                                    self?.stallObserverLoop(channelType, index, conn, relayClient)
                                }
                            }
                        }
                    }
                    catch {
                        SCIONStack.shared.clearSciondCache()
                        fatalError("Failed setting up relays: \(error)")
                    }
                }
                else {
                    self.operationMode = .normal
                }
                
                client = WebRTCClient(iceServers: [], operationMode: self.operationMode)
                client.delegate = self
                client.startCaptureLocalVideo(renderer: nil)
                
                self.hasRemoteSdp = true
                self.callState = .incomingRequest(client)
            }
            else {
                // print("Received SDP but wasn't expecting one")
                return
            }
            
            client.set(remoteSdp: sdp) { error in
                if let error = error {
                    print("SDP Error: \(error)")
                }
                else {
                    DispatchQueue.main.async {
                        if !self.callState.isCallInitiator && autoDialCall {
                            self.answerCall()
                        }
                        
                        if self.operationMode != .normal {
                            // When we have the remote sdp and all fake remote candidates we can start adding the candidates to the rtc client
                            // TODO: keep track of whether fake candidates already added
                            self.tryCompletingCallSetup(client: client)
                        }
                    }
                }
            }
        }
    }
    
    func tryCompletingCallSetup(client: WebRTCClient) {
        assert(operationMode != .normal)
        if self.hasRemoteSdp && self.fakeRemoteCandidates.allSatisfy({ $0 != nil }) {
            print("Call setup complete")
            self.fakeRemoteCandidates.compactMap({ $0 }).forEach {
                client.add(remoteCandidate: $0)
            }
        }
    }
    
    func signalClient(_ signalClient: SignalingClient, didReceiveCandidate candidate: RTCIceCandidate) {
        guard Date().timeIntervalSince(lastHangUpTime) > 2 else { return }
        
        guard let client = callState.client else {
//            print("Got remote ICE candidate but no RTC session is in progress!")
            return
        }
        
        if operationMode == .normal {
            print("Received remote candidate: \(candidate)")
            DispatchQueue.main.async {
                self.remoteCandidateCount += 1
            }
            client.add(remoteCandidate: candidate)
        }
        else {
            let index = Int(candidate.sdpMLineIndex)
            guard fakeRemoteCandidates[index] == nil else {
                // print("Got ICE candidate for channel \(index) but already have one")
                return
            }
            
            print("Got remote ICE candidate")
            
            DispatchQueue.main.async {
                self.remoteCandidateCount += 1
            }
            
            var sdpComponents = candidate.sdp.components(separatedBy: " ")
            // Important here is that the channels are in the correct order, matching the sdp line index of the channels. It is currently fixed in this order: audio, video, data.
            guard let relayPort = relayAdapter?.channels[index].1.port?.rawValue else {
                return
            }
            
            sdpComponents[5] = "\(relayPort)"
            let fakeRemoteCandidate = RTCIceCandidate(sdp: sdpComponents.joined(separator: " "), sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
            
            fakeRemoteCandidates[index] = fakeRemoteCandidate
            // When we have the remote sdp and all fake remote candidates we can start adding the candidates to the rtc client
            // TODO: keep track of whether fake candidates already added
            tryCompletingCallSetup(client: client)
        }
    }
}

extension VideoChatSession: WebRTCClientDelegate {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate) {
        guard callState != .idle else {
            print("Generated ICE candidate but call state is idle!")
            return
        }

        if operationMode != .normal {
            if !candidate.sdp.contains("1 udp") { // want RTP udp channel. RTCP will be multiplexed over this same channel.
                return
            }
            if !candidate.sdp.contains("127.0.0.1") { // want loopback candidate
                return
            }
            
            let index = Int(candidate.sdpMLineIndex)
            assert(localCandidates[index] == nil)
            
            localCandidates[index] = candidate
        }

        print("local candidate: \(candidate)")
        DispatchQueue.main.async {
            self.localCandidateCount += 1
        }
        
        func sendCandidate() {
            do {
                print("Sending ICE candidate")
                try signalingClient.send(candidate: candidate)
            }
            catch {
                print("Signaling send failed: \(error)")
            }
        }
        
        sendCandidate()
        
        var extraSends = 3
        DispatchQueue.main.async {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                if self.callState.isCallSetupPhase {
                    sendCandidate()
                }
                else {
                    if extraSends == 0 {
                        timer.invalidate()
                    }
                    else {
                        sendCandidate()
                        extraSends -= 1
                    }
                }
            }
        }
    }
    
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
        guard case .ongoing(_, _, _) = callState else {
            print("No call is ongoing!")
            return
        }
        
        DispatchQueue.main.async {
            guard case let .ongoing(initiator, client, _) = self.callState else {
                print("No call is ongoing!")
                return
            }
            self.callState = .ongoing(initiator, client, state)
        }
    }
    
    func webRTCClient(_ client: WebRTCClient, didReceiveData data: Data) {
        fatalError()
    }
}

/// Mark: - Statistics

extension VideoChatSession {
    private func decodeStatsDict<D: Decodable>(_ dict: [String: NSObject], into type: D.Type) throws -> D {
        //        let decoded = try DictionaryDecoder().decode(type, from: dict)
        let encoded = try JSONSerialization.data(withJSONObject: dict, options: [])
        return try JSONDecoder().decode(type, from: encoded)
    }
    
    private func generateStatisticsReport(_ stats: RTCStatisticsReport) {
        var audioOutboundRTP: AudioOutboundRTPStats?
        var audioSenderTrack: TrackSenderAudioRTCStats?
        var audioReceiverTrack: TrackReceiverAudioRTCStats?
        var audioRemoteInboundRTP: RemoteInboundRTPStats?
        
        var videoOutboundRTP: VideoOutboundRTPStats?
        var videoSenderTrack: TrackSenderVideoRTCStats?
        var videoReceiverTrack: TrackReceiverVideoRTCStats?
        var videoRemoteInboundRTP: RemoteInboundRTPStats?
        var videoInboundRTP: VideoInbountRTPStats?
        
        var transports = [String: TransportWebRTCStats]()
        
        for (_, stat) in stats.statistics {
            if stat.type == "outbound-rtp" {
                do {
                    if stat.values["kind"] as? String == "audio" {
                        let decoded = try self.decodeStatsDict(stat.values, into: AudioOutboundRTPStats.self)
                        assert(audioOutboundRTP == nil)
                        audioOutboundRTP = decoded
                    }
                    else {
                        let decoded = try self.decodeStatsDict(stat.values, into: VideoOutboundRTPStats.self)
                        assert(videoOutboundRTP == nil)
                        videoOutboundRTP = decoded
                    }
                }
                catch {
                    print(error)
                    fatalError()
                }
                //                print("Outbound RTP \(key), \(stat.id):\n\(stat.values)\n\n")
            }
            
            else if stat.type == "remote-inbound-rtp" {
                do {
                    let decoded = try self.decodeStatsDict(stat.values, into: RemoteInboundRTPStats.self)
                    if decoded.kind == .audio {
                        assert(audioRemoteInboundRTP == nil)
                        audioRemoteInboundRTP = decoded
                    }
                    else {
                        assert(videoRemoteInboundRTP == nil)
                        videoRemoteInboundRTP = decoded
                    }
                }
                catch {
                    print(error)
                    fatalError()
                }
                //                print("Remote inbound RTP \(key), \(stat.id):\n\(stat.values)\n\n")
            }
            //                        else if stat.type == "remote-outbound-rtp" {
            //                            print("Remote outbound RTP \(key), \(stat.id):\n\(stat.values)\n\n")
            //                        }
            else if stat.type == "track" {
                do {
                    if stat.id.contains("receiver") {
                        if stat.values["kind"] as? String == "audio" {
                            let decoded = try self.decodeStatsDict(stat.values, into: TrackReceiverAudioRTCStats.self)
                            assert(audioReceiverTrack == nil)
                            audioReceiverTrack = decoded
                        }
                        else {
                            let decoded = try self.decodeStatsDict(stat.values, into: TrackReceiverVideoRTCStats.self)
                            assert(videoReceiverTrack == nil)
                            videoReceiverTrack = decoded
                        }
                    }
                    else {
                        if stat.values["kind"] as? String == "audio" {
                            let decoded = try self.decodeStatsDict(stat.values, into: TrackSenderAudioRTCStats.self)
                            assert(audioSenderTrack == nil)
                            audioSenderTrack = decoded
                        }
                        else {
                            let decoded = try self.decodeStatsDict(stat.values, into: TrackSenderVideoRTCStats.self)
                            assert(videoSenderTrack == nil)
                            videoSenderTrack = decoded
                        }
                    }
                }
                catch {
                    print(error)
                    fatalError()
                }
                //                print("Track \(key), \(stat.id):\n\(stat.values)\n\n")
            }
            //            else if stat.type == "media-source" {
            //                print("Media source \(key), \(stat.id):\n\(stat.values)\n\n")
            //            }
            //            else if stat.type == "stream" {
            //                print("Stream \(key), \(stat.id):\n\(stat.values)\n\n")
            //            }
            else if stat.type == "transport" {
                do {
                    let decoded = try self.decodeStatsDict(stat.values, into: TransportWebRTCStats.self)
                    transports[stat.id] = decoded
                }
                catch {
                    print(error)
                    fatalError()
                }
                //                print("Transport \(key), \(stat.id):\n\(stat.values)\n\n")
            }
            else if stat.type == "inbound-rtp" {
                do {
                    if stat.values["kind"] as? String == "video" {
                        let decoded = try self.decodeStatsDict(stat.values, into: VideoInbountRTPStats.self)
                        videoInboundRTP = decoded
                    }
                }
                catch {
                    print(error)
                    fatalError()
                }
                
            }
            //            else if stat.type == "data-channel" {
            //                print("Data channel \(key), \(stat.id):\n\(stat.values)\n\n")
            //            }
            //            else if stat.type == "codec" {
            //                print("Codec \(key), \(stat.id):\n\(stat.values)\n\n")
            //            }
            //            else if stat.type == "certificate" {
            //                print("Certificate \(key), \(stat.id):\n\(stat.values)\n\n")
            //            }
            //            else if stat.type == "peer-connection" {
            //                print("Peer connection \(key), \(stat.id):\n\(stat.values)\n\n")
            //            }
        }
        //        print(Set(stats.statistics.values.map{ $0.type }))
        
        guard
            let _audioOutboundRTP = audioOutboundRTP,
            let _audioSenderTrack = audioSenderTrack,
            let _audioReceiverTrack = audioReceiverTrack,
            let _audioRemoteInboundRTP = audioRemoteInboundRTP,
            let _videoOutboundRTP = videoOutboundRTP,
            let _videoSenderTrack = videoSenderTrack,
            let _videoReceiverTrack = videoReceiverTrack,
            let _videoRemoteInboundRTP = videoRemoteInboundRTP,
            let _videoInboundRTP = videoInboundRTP,
            let audioTransport = transports[_audioOutboundRTP.transportId],
            let videoTransport = transports[_videoOutboundRTP.transportId]
        else {
            print("Invalid statistics report!")
            return
        }
        
        if _audioOutboundRTP.transportId == _videoOutboundRTP.transportId {
            print("WARNING: Audio and video use same transport! This may affect readings that assume audio and video use different transports")
        }
        
        let audioReport = StatisticsReportAudio(outboundRTP: _audioOutboundRTP, transport: audioTransport, senderTrack: _audioSenderTrack, receiverTrack: _audioReceiverTrack, remoteInboundRTP: _audioRemoteInboundRTP)
        
        let videoReport = StatisticsReportVideo(outboundRTP: _videoOutboundRTP, transport: videoTransport, senderTrack: _videoSenderTrack, receiverTrack: _videoReceiverTrack, remoteInboundRTP: _videoRemoteInboundRTP, inboundRTP: _videoInboundRTP)
        
        let report = StatisticsReport(audio: audioReport, video: videoReport)
        
        switch self.remoteRelay {
        case .scion(.server(let server)):
            server.callQualityMonitors.forEach { _, monitor in
                monitor.consume(next: report)
            }
            
        case .scion(.client(let client)):
            client.callQualityMonitors.forEach { _, monitor in
                monitor.consume(next: report)
            }
            
        default: break
        }
        
        self.latestReport = report
        DispatchQueue.main.async {
            self.reportPublisher.send(report)
        }
        //        print("\n\nNew report:\n\(report)\n\n\n###################################################\n###################################################\n\n")
    }
    
    private func startGatheringStats() {
        guard !gatheringStats else {
            print("Already gathering stats!!")
            return
        }
        gatheringStats = true
        
        func gather() {
            guard let client = callState.client else { return }
            
            client.getStatisticsReport()
                .autoDisposableSink(receiveValue: { stats in
                    self.generateStatisticsReport(stats)
                    self.statsQueue.asyncAfter(deadline: .now() + 1) {
                        gather()
                    }
                })
        }
        
        statsQueue.async {
            gather()
        }
    }
}
