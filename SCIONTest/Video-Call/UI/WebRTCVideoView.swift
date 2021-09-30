//
//  WebRTCVideoView.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 21.06.21.
//

import Foundation
import SwiftUI
import WebRTC

#if os(macOS)
struct WebRTCVideoView: NSViewRepresentable {
    let client: WebRTCClient
    
    func makeNSView(context: Context) -> NSView {
        let height = 60.0
        let width = height * 16/9
        
        let localRenderer = RTCMTLNSVideoView(frame: CGRect(x: 5, y: 5, width: width, height: height))
        let remoteRenderer = RTCMTLNSVideoView(frame: .zero)
        //        localRenderer.videoContentMode = .scaleAspectFill
        //        remoteRenderer.videoContentMode = .scaleAspectFill
        
        client.startCaptureLocalVideo(renderer: localRenderer)
        client.renderRemoteVideo(to: remoteRenderer)
        
        remoteRenderer.addSubview(localRenderer)
        
        localRenderer.wantsLayer = true
        localRenderer.layer?.borderWidth = 1
        localRenderer.layer?.borderColor = NSColor.black.cgColor
        
        remoteRenderer.translatesAutoresizingMaskIntoConstraints = false
        
        remoteRenderer.wantsLayer = true
        remoteRenderer.layer?.borderWidth = 1
        remoteRenderer.layer?.borderColor = NSColor.black.cgColor
        
        return remoteRenderer
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
    }
}
#elseif targetEnvironment(simulator)
struct WebRTCVideoView: View {
    var body: some View {
        VStack {
            Text("Preview not available on simulator").font(.headline)
            Text("It can work in theory b/c simulator now supports Metal. But WebRTC might need an update")
        }
    }
}
#else
struct WebRTCVideoView: UIViewRepresentable {
    let client: WebRTCClient
    
    func makeUIView(context: Context) -> UIView {
        let width = 40.0
        let height = width * 16/9
        let localRenderer = RTCMTLVideoView(frame: CGRect(x: 5, y: 5, width: width, height: height))
        let remoteRenderer = RTCMTLVideoView(frame: .zero)
        localRenderer.videoContentMode = .scaleAspectFill
        remoteRenderer.videoContentMode = .scaleAspectFill
        
        client.startCaptureLocalVideo(renderer: localRenderer)
        client.renderRemoteVideo(to: remoteRenderer)
        
        remoteRenderer.addSubview(localRenderer)
        
        remoteRenderer.translatesAutoresizingMaskIntoConstraints = false
        
        return remoteRenderer
    }
    
    func updateUIView(_ nsView: UIView, context: Context) {
    }
}
#endif
