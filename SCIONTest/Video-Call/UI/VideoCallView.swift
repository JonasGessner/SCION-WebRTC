//
//  VideoCallView.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 18.03.21.
//

import Foundation
import WebRTC
import SwiftUI

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}

struct CallVideoViewPlaceHolder: View {
    var body: some View {
        Text("Hit that call button")
    }
}

struct VideoCallView: View {
    @Environment(\.openURL) var openURL
    
    @ObservedObject private var session = VideoChatSession.shared
    
    @State private var lastPenalties = [(ChannelType, Penalty, Date)]()
    
    struct ConnView: View {
//        let name: String
        @ObservedObject var connection: SCIONUDPConnection
        let pressDaButtonMan: () -> Void
        
        var body: some View {
            let inPath = connection.mirrorReplyPath?.path.canonicalFingerprintShortWithTCInfo ?? "-"
            let outPath = connection.effectivePath?.canonicalFingerprintShortWithTCInfo ?? "-"
            
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("In:\t\(inPath)")
                }
                
                HStack {
                    Text("Out:\t\(outPath)")
                    
                    Button("Select") {
                        pressDaButtonMan()
                    }
                }
            }
            .padding(5)
            .background(Color(white: 0, opacity: 0.1).cornerRadius(8))
        }
    }
    
    func relayConnections() -> [(ChannelType, SCIONUDPConnection)] {
        guard session.operationMode == .relaySCION, let relay = session.remoteRelay else { return [] }

        switch relay {
        case .scion(.client(let client)):
            return client.channels
        case .scion(.server(let server)):
            return zip(server.channels.map({ $0.0 }), server.connections.map({ $0.first?.0 }))
                .compactMap({
                    if let conn = $1 {
                        return ($0, conn)
                    }
                    return nil
                })
        default: fatalError()
        }
    }
    
    private func categorized(_ relayConnections: [(ChannelType, SCIONUDPConnection)]) -> [(ChannelType, [SCIONUDPConnection])] {
        return
            Dictionary(relayConnections.filter({ $0.0 != .data }).map({ ($0.0, [$0.1]) }), uniquingKeysWith: { a, b in
                a + b
            })
            .mapValues({ $0.sorted(by: { $0.fullPathProcessor.processors.count < $1.fullPathProcessor.processors.count }) })
            .map({ $0 })
            .sorted(by: { $0.key.rawValue < $1.key.rawValue })
    }
    
    @State private var pathSheetConn: SCIONUDPConnection?
    @State private var statsViewPushed = false
    
    @State private var extraVideoConns = 0
    @State private var extraAudioConns = 0
    
    @State private var fixPaths = false
    @State private var latencyProbingPaused = LatencyProbingPathProcessor.latencyProbingPaused
    @State private var penaltiesPaused = !CallQualityMonitor.sendingEnabled
    
    var body: some View {
        Form {
            Section(header: Text("WebRTC Status").font(.title3).bold()) {
                Text("Signaling Connection: \(session.signalingConnected ? "✅" : "❌")")
                Text("SDP Local/Remote: \(session.hasLocalSdp ? "✅" : "❌")/\(session.hasRemoteSdp ? "✅" : "❌")")
                Text("ICE Candidates Local/Remote: \(session.localCandidateCount)/\(session.remoteCandidateCount)")
            }
            Divider()
            
            Section {
                let relayConnections = self.relayConnections()
                if !relayConnections.isEmpty {
                    let categorized = categorized(relayConnections)
                    
                    ForEach(categorized, id: \.0) { type, conns in
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Paths for \(type.rawValue.capitalized):")
                                .bold()
                            
                            HStack {
                                ForEach(conns, id: \.self) { conn in
                                    ConnView(connection: conn) {
                                        pathSheetConn = conn
                                    }
                                }
                            }
                        }
                    }
                    
                    Toggle("Fix current paths", isOn: $fixPaths)
                        .onChange(of: fixPaths) { fixPaths in
                            self.relayConnections().forEach { _, connection in
                                if fixPaths {
                                    connection.fixedPath = connection.pathProcessorChosenPath
                                }
                                else {
                                    connection.fixedPath = nil
                                }
                            }
                        }
                }
                
                Toggle("Pause latency probing", isOn: $latencyProbingPaused)
                    .onChange(of: latencyProbingPaused) { latencyProbingPaused in
                        LatencyProbingPathProcessor.latencyProbingPaused = latencyProbingPaused
                    }
                
                Toggle("Pause WebRTC metrics penalties", isOn: $penaltiesPaused)
                    .onChange(of: penaltiesPaused) { paused in
                        CallQualityMonitor.sendingEnabled = !paused
                    }
            }
            
            switch session.callState {
            case .idle:
                // These steppers completely mess up the layout. All other sections align to the stepper control, which means that if the stepper is not at the very left of the view all other sections become inset
                Divider()
                
                Section(header: Text("Call Setup").font(.title3).bold()) {
                    HStack {
                        Stepper("", value: $extraAudioConns, in: 0...2)
                        Text("Extra audio connections: \(extraAudioConns)")
                    }
                    
                    HStack {
                        Stepper("", value: $extraVideoConns, in: 0...2)
                        Text("Extra video connections: \(extraVideoConns)")
                    }
                }
                
            case .ongoing(let initiator, _, let rtcState):
                Divider()
                
                Section(header: Text("Call State").font(.title3).bold()) {
                    HStack {
                        Text("Call in progress. RTC state \(rtcState.description). Initiator: \(initiator ? "yes" : "no")")
                     
                        Spacer()
                        
                        Button("Hang Up") {
                            session.hangUp()
                            fixPaths = false
                        }
                    }
                }
                
                if displayInlineWebRTCMetrics {
                    Divider()
                    
                    Section {
                        let h = 160 + (lastPenalties.isEmpty ? 0 : 34) + lastPenalties.count * 12
                        VideoCallStatsView(detailed: false, lastPenalties: lastPenalties)
                            .frame(maxWidth: .infinity, maxHeight: CGFloat(h), alignment: .center)
                    }
                }

            default: Group {}
            }

            #if os(iOS)
            NavigationLink(
                destination: Group { VideoCallStatsView() },
                isActive: $statsViewPushed,
                label: {
                    
                })
            #endif
            
            Divider()
            
            Section {
                if let client = session.callState.client {
                    ZStack(alignment: .topTrailing) {
                        WebRTCVideoView(client: client)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .allowsHitTesting(false)
                            .background(
                                ZStack {
                                    Color(white: 0, opacity: 0.1)
                                    
                                    switch session.callState {
                                    case .requestedOutgoing:
                                        VStack {
                                            Text("Ringing")
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle())
                                            Spacer().frame(height: 10)
                                            Button("Hang Up") {
                                                session.hangUp()
                                                fixPaths = false
                                            }
                                        }
                                    case .incomingRequest:
                                        VStack {
                                            Text("Incoming Call!")
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle())
                                            Spacer().frame(height: 10)
                                            Button("Pick Up") {
                                                session.answerCall()
                                            }
                                            Button("Decline") {
                                                session.hangUp()
                                            }
                                        }
                                    default: Group {}
                                    }
                                }
                            )
                        
                        HStack(spacing: 5) {
                            Button {
                                session.sendingAudio.toggle()
                            } label: {
                                if !session.sendingAudio {
                                    Image(systemName: "speaker.slash.fill")
                                }
                                else {
                                    Image(systemName: "speaker.wave.3.fill")
                                    
                                }
                            }
                            .foregroundColor(.red)
                            .buttonStyle(BorderlessButtonStyle())
                            .padding()
                            
                            Button {
                                session.sendingVideo.toggle()
                            } label: {
                                if !session.sendingVideo {
                                    Image(systemName: "video.slash.fill")
                                }
                                else {
                                    Image(systemName: "video.fill")
                                }
                            }
                            .foregroundColor(.red)
                            .buttonStyle(BorderlessButtonStyle())
                            .padding()
                        }
                    }
                }
                else {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button("Call") {
                                session.offerCall(numberOfVideoChannels: 1 + extraVideoConns, numberOfAudioChannels: 1 + extraAudioConns)
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .toolbar(content: {
            #if os(macOS)
            let p = ToolbarItemPlacement.primaryAction
            #else
            let p = ToolbarItemPlacement.navigationBarTrailing
            #endif
            
            ToolbarItem(placement: p) {
                Button("Show Detailed Stats") {
                    #if os(macOS)
                    openURL(URL(string: "sciontest://stats")!)
                    #else
                    statsViewPushed = true
                    #endif
                }
            }
        })
        .sheet(item: $pathSheetConn, content: { c in
            PathSelectionView(connection: c, done: { pathSheetConn = nil }, initialProcessor: c.fullPathProcessor, showProcessorOptions: false, selectedProcessor: c.fullPathProcessor)
        })
        .onReceive(session.$callState, perform: { state in
            if state == .idle {
                self.lastPenalties = []
            }
        })
        .onAppear {
            NotificationCenter.default.addObserver(forName: NSNotification.Name("PathPenalty"), object: nil, queue: .main) { n in
                let penalties = n.userInfo?["penalties"] as! [Penalty]
                let channel = n.userInfo!["channel"] as! ChannelType
                
                var p = self.lastPenalties
                p.insert(contentsOf: penalties.map({ (channel, $0, Date()) }), at: 0)
                self.lastPenalties = Array(p.prefix(3))
            }
            
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: // The user has not yet been asked for camera access.
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                }
            case .authorized:
                break
            case .denied: // The user has previously denied access.
                break
            case .restricted: // The user can't grant access due to restrictions.
                break
            @unknown default:
                break
            }
            
            // Don't need video permissions when not even using camera
            guard !useBigChungus else { return }
            
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined: // The user has not yet been asked for camera access.
                AVCaptureDevice.requestAccess(for: .video) { _ in
                }
            case .authorized:
                break
            case .denied: // The user has previously denied access.
                break
            case .restricted: // The user can't grant access due to restrictions.
                break
            @unknown default:
                break
            }
        }
    }
}

struct PresentableVideoCallView: View {
    @ObservedObject private var stack = SCIONStack.shared
    @State private var h: CGFloat = 900.0
    
    var body: some View {
        Group {
            if stack.initialized {
                #if os(macOS)
                (isCloud() ? Color(.systemOrange) : Color(.systemTeal))
                    .frame(maxWidth: .infinity, minHeight: 10, idealHeight: 10, maxHeight: 10)
                    .padding(0)
                VideoCallView()
                    .padding(.vertical, 5).padding(.horizontal, 20)
                    .toolbar {
                        Spacer()
                    }
                    // Hack to set the initial window size to a fixed value but allow making it smaller or larger manually later.
                    .frame(minHeight: h)
                    .onAppear {
                        if h != 0 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                h = 0
                            }
                        }
                    }
                #else
                VideoCallView()
                #endif
            }
            else {
                Spacer().frame(minWidth: 300,  minHeight: 400)
            }
        }
    }
}
