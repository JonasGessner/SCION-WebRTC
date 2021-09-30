//
//  WebRTCClient.swift
//  WebRTC
//
//  Created by Stasel on 20/05/2018.
//  Copyright © 2018 Stasel. All rights reserved.
//

import Foundation
import WebRTC
import Network
import Combine

protocol WebRTCClientDelegate: AnyObject {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate)
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCClient(_ client: WebRTCClient, didReceiveData data: Data)
}

@available(iOS 12.0, *)
/// Wrapper around WebRTC for easier call configuration and management
final class WebRTCClient: NSObject {
    enum OperationMode: Equatable {
        case normal // Normal WebRTC with STUN, no TURN
        case relayUDP // Local call where channels are manually relayed via UDP. For debugging
        case relaySCION // Internet call where channels are relayed via SCION sockets
    }
    
    weak var delegate: WebRTCClientDelegate?
    private let peerConnection: RTCPeerConnection
    #if !os(macOS)
    private let rtcAudioSession =  RTCAudioSession.sharedInstance()
    #endif
    private let audioQueue = DispatchQueue(label: "audio")
    private let mediaConstrains = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue]    
    private var videoCapturer: RTCVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    
    private var remoteVideoTrack: RTCVideoTrack?
//    private var localDataChannel: RTCDataChannel?
//    private var remoteDataChannel: RTCDataChannel?

    let operationMode: OperationMode
    
    private let factory: RTCPeerConnectionFactory
    
    @available(*, unavailable)
    override init() {
        fatalError("WebRTCClient:init is unavailable")
    }
    
    static let configSSL = {
        RTCInitializeSSL()
    }()
    
    required init(iceServers: [String], operationMode: OperationMode) {
        guard WebRTCClient.configSSL else {
            fatalError()
        }

        let config = RTCConfiguration()
        
        if iceServers.isEmpty {
            config.iceServers = []
        }
        else {
            config.iceServers = [RTCIceServer(urlStrings: iceServers)]
        }

        config.iceTransportPolicy = .all
        config.rtcpMuxPolicy = .require
        config.sdpSemantics = .unifiedPlan
        config.disableIPV6 = true
        
        // gatherContinually will let WebRTC to listen to any network changes and send any new candidates to the other client
        // Gathering continually is only needed when going a call in normal operation mode over the internet. Doing a call over LAN or relayed will no need continual gathering.
        config.continualGatheringPolicy = .gatherOnce
        
        // Define media constraints. DtlsSrtpKeyAgreement is required to be true to be able to connect with web browsers.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        let factory = RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        
        if operationMode == .normal {
            let options = RTCPeerConnectionFactoryOptions()
            options.ignoreVPNNetworkAdapter = true
            options.ignoreCellularNetworkAdapter = true
            options.ignoreEthernetNetworkAdapter = true
            options.ignoreWiFiNetworkAdapter = false
            options.ignoreLoopbackNetworkAdapter = true
            factory.setOptions(options)
        }
        else {
            let options = RTCPeerConnectionFactoryOptions()
            options.ignoreVPNNetworkAdapter = true
            options.ignoreCellularNetworkAdapter = true
            options.ignoreEthernetNetworkAdapter = true
            options.ignoreWiFiNetworkAdapter = true
            options.ignoreLoopbackNetworkAdapter = false
            factory.setOptions(options)
        }
        
        self.peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: nil)!
        self.operationMode = operationMode
        self.factory = factory
        
        super.init()
        self.createMediaSenders()
        self.configureAudioSession()
        self.peerConnection.delegate = self
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name("FailoverHappened"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
           
            // Try to get WebRTC to pump up its resolution. Its bandwidth estimator sometimes really sucks and can get stuck at 180p indefinitely.
            if !self.peerConnection.setBweMinBitrateBps(NSNumber(value: 800000), currentBitrateBps: NSNumber(value: 1000000), maxBitrateBps: NSNumber(value: 10000000)) {
                print("Setting min BW failed")
            }
        }
        
        if !audioEnabledDefault {
            muteAudio()
        }
        if !videoEnabledDefault {
            hideVideo()
        }
    }
    
    // To be able to record things check this: https://github.com/HackWebRTC/webrtc/commit/dfbcd2c75d27dafd24512d6ca3d24c6d86d63b82
    
    func getStatisticsReport() -> Future<RTCStatisticsReport, Never> {
        return Future { promsie in
            self.peerConnection.statistics(completionHandler: { report in
                promsie(.success(report))
            })
        }
    }
    
    private func processSDP(_ sdp: RTCSessionDescription) -> RTCSessionDescription {
        var transformedSDP = sdp
        
        if self.operationMode != .normal {
            transformedSDP = RTCSessionDescription(type: transformedSDP.type, sdp: transformedSDP.sdp.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1"))
            
            // Turn off bundling entirely so that we have separate network streams (tcp/udp) for video, audio and data.
            transformedSDP = RTCSessionDescription(type: transformedSDP.type, sdp: transformedSDP.sdp.replacingOccurrences(of: "a=group:BUNDLE 0 1 2\r\n", with: ""))
            
            // Turn off bundling entirely so that we have separate network streams (tcp/udp) for video, audio and data.
            transformedSDP = RTCSessionDescription(type: transformedSDP.type, sdp: transformedSDP.sdp.replacingOccurrences(of: "a=group:BUNDLE 0 1\r\n", with: ""))
        }
        
        // Need to fix the used video profile on macOS to be compatible with iOS
        #if os(macOS)
        transformedSDP = RTCSessionDescription(type: transformedSDP.type, sdp: transformedSDP.sdp.replacingOccurrences(of: "1f\r\na=rtpmap", with: "2a\r\na=rtpmap"))
        #endif
        
        return transformedSDP
    }
    
    // MARK: Signaling
    func offer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void) {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection.offer(for: constrains) { (sdp, error) in
            guard let sdp = sdp else {
                return
            }
            
            let finalSDP = self.processSDP(sdp)

            self.peerConnection.setLocalDescription(finalSDP) { (error) in
                if let err = error { print("WTF ERROR \(err)")}
                completion(finalSDP)
            }
        }
    }
    
    func answer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void)  {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection.answer(for: constrains) { (sdp, error) in
            guard let sdp = sdp else {
                return
            }
            
            let finalSDP = self.processSDP(sdp)
            
            self.peerConnection.setLocalDescription(finalSDP, completionHandler: { (error) in
                completion(finalSDP)
            })
        }
    }
    
    func set(remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> ()) {
        self.peerConnection.setRemoteDescription(remoteSdp, completionHandler: completion)
    }
    
    func add(remoteCandidate: RTCIceCandidate) {
        self.peerConnection.add(remoteCandidate) { error in
            if let error = error {
                print("Add candidate error \(error)")
            }
        }
    }
    
    func hangUp() {
        peerConnection.close()
        if let capturer = self.videoCapturer as? RTCFileVideoCapturer {
            capturer.stopCapture()
        }
    }
    
    // MARK: Media
    func startCaptureLocalVideo(renderer: RTCVideoRenderer?) {
        DispatchQueue.global(qos: .userInteractive).async {
            if let capturer = self.videoCapturer as? RTCFileVideoCapturer {
                capturer.startCapturing(fromFileNamed: useWhiteVideo ? "white.mov" : (isCloud() ? "Caminandes\(caminandesVersion).mp4" : "BigBuckBunny\(bigChungusVersion).mp4")) { error in
                    print("Video file capture error \(error)")
                }
                
                renderer.map { self.localVideoTrack!.add($0) }
                
                return
            }
            
            guard let capturer = self.videoCapturer as? RTCCameraVideoCapturer else {
                return
            }
            
            guard
                let frontCamera = (RTCCameraVideoCapturer.captureDevices().first { $0.position == .front }) ?? RTCCameraVideoCapturer.captureDevices().first,
                
                // choose highest res
                let format = (RTCCameraVideoCapturer.supportedFormats(for: frontCamera).sorted { (f1, f2) -> Bool in
                    let width1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription).width
                    let width2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription).width
                    return width1 < width2
                }).last,
                
                // choose highest fps
                let fps = (format.videoSupportedFrameRateRanges.sorted { return $0.maxFrameRate < $1.maxFrameRate }.last) else {
                return
            }
            
            capturer.startCapture(with: frontCamera,
                                  format: format,
                                  fps: Int(fps.maxFrameRate))
            
            renderer.map { self.localVideoTrack!.add($0) }
        }
    }
    
    func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        self.remoteVideoTrack!.add(renderer)
    }
    
    private func configureAudioSession() {
        #if !os(macOS)
        self.rtcAudioSession.lockForConfiguration()
        do {
            try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue)
            try self.rtcAudioSession.setMode(AVAudioSession.Mode.voiceChat.rawValue)
        } catch let error {
            debugPrint("Error changeing AVAudioSession category: \(error)")
        }
        self.rtcAudioSession.unlockForConfiguration()
        #endif
    }
    
    private func createMediaSenders() {
        let streamId = "stream"
        
        // Audio
        let audioTrack = self.createAudioTrack()
        localAudioTrack = audioTrack
        self.peerConnection.add(audioTrack, streamIds: [streamId])
        
        // Video
        let videoTrack = self.createVideoTrack()
        self.localVideoTrack = videoTrack
        self.peerConnection.add(videoTrack, streamIds: [streamId])
        self.remoteVideoTrack = self.peerConnection.transceivers.first { $0.mediaType == .video }!.receiver.track as! RTCVideoTrack?
        // Data
//        if let dataChannel = createDataChannel() {
//            dataChannel.delegate = self
//            self.localDataChannel = dataChannel
//        }
    }
    
    // macOS WebRtC bug https://groups.google.com/g/discuss-webrtc/c/AVeyMXnM0gY
    
    private func createAudioTrack() -> RTCAudioTrack {
        let audioConstrains = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstrains)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        return audioTrack
    }
    
    private func createVideoTrack() -> RTCVideoTrack {
        let videoSource = factory.videoSource()
        
        #if targetEnvironment(simulator)
        self.videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
        #else
        if useBigChungus {
            self.videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
        }
        else {
            self.videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        }
        #endif
        
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        return videoTrack
    }
    
//    // MARK: Data Channels
//    private func createDataChannel() -> RTCDataChannel? {
//        let config = RTCDataChannelConfiguration()
//        guard let dataChannel = self.peerConnection.dataChannel(forLabel: "WebRTCData", configuration: config) else {
//            debugPrint("Warning: Couldn't create data channel.")
//            return nil
//        }
//        return dataChannel
//    }
//
//    func sendData(_ data: Data) {
//        let buffer = RTCDataBuffer(data: data, isBinary: true)
//        self.remoteDataChannel?.sendData(buffer)
//    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        debugPrint("peerConnection new signaling state: \(stateChanged)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        debugPrint("peerConnection did add stream")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        debugPrint("peerConnection did remove stream")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        debugPrint("peerConnection should negotiate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        debugPrint("peerConnection new connection state: \(newState)")
        self.delegate?.webRTCClient(self, didChangeConnectionState: newState)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        debugPrint("peerConnection new gathering state: \(newState)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        self.delegate?.webRTCClient(self, didDiscoverLocalCandidate: candidate)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        debugPrint("peerConnection did remove candidate(s)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        debugPrint("peerConnection did open data channel")
//        self.remoteDataChannel = dataChannel
    }
}
extension WebRTCClient {
    private func setTrackEnabled<T: RTCMediaStreamTrack>(_ type: T.Type, isEnabled: Bool) {
        peerConnection.transceivers
            .compactMap { return $0.sender.track as? T }
            .forEach { $0.isEnabled = isEnabled }
    }
}

// MARK: - Video control
extension WebRTCClient {
    func hideVideo() {
        self.setVideoEnabled(false)
    }
    func showVideo() {
        self.setVideoEnabled(true)
    }
    private func setVideoEnabled(_ isEnabled: Bool) {
        localVideoTrack?.isEnabled = isEnabled
    }
}
// MARK:- Audio control
extension WebRTCClient {
    func muteAudio() {
        self.setAudioEnabled(false)
    }
    
    func unmuteAudio() {
        self.setAudioEnabled(true)
    }
    
    // Fallback to the default playing device: headphones/bluetooth/ear speaker
    func speakerOff() {
        self.audioQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            
            #if !os(macOS)
            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue)
                try self.rtcAudioSession.overrideOutputAudioPort(.none)
            } catch let error {
                debugPrint("Error setting AVAudioSession category: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
            #endif
        }
    }
    
    // Force speaker
    func speakerOn() {
        self.audioQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            
            #if !os(macOS)
            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue)
                try self.rtcAudioSession.overrideOutputAudioPort(.speaker)
                try self.rtcAudioSession.setActive(true)
            } catch let error {
                debugPrint("Couldn't force audio to speaker: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
            #endif
        }
    }
    
    private func setAudioEnabled(_ isEnabled: Bool) {
        localAudioTrack?.isEnabled = isEnabled
    }
}

extension WebRTCClient: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        debugPrint("dataChannel did change state: \(dataChannel.readyState)")
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        self.delegate?.webRTCClient(self, didReceiveData: buffer.data)
    }
}
