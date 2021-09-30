//
//  Options.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 23.04.21.
//

import Foundation

// Options than can be set under 'Active Compilcation Conditions':
// GATHER_RELAY_FREEZE_STATS
// GATHER_UDP_RELAY_COUNTERS

// let defaultSignalingServerUrl = URL(string: "ws://put-address-here")!
let defaultSignalingServerUrl = URL(string: "ws://netsec-jgessner.inf.ethz.ch")!
let useBigChungus = true // Whether to use big buck bunny as video source instead of the camera

let disableCallQualityMonitoring = false

let onlyCall = true // Launch straight to the call view instead of view selector
let straightToCall = false // Automatically open call view
let autoDialCall = testCase.isVideoCallTest // Automatically dial a call when call view is opened
let skipSCIONSetup = false // Overrides autoConnectSCION
let autoConnectSCION = true // Connects iPhone to Madgeburg, macOS to ETH with the default BR IP addresses
let autofillMessengerClientField = true // Autofill the server address in the client text field in the chat view.

let useStallMonitor = false // Should normally be false!! This enables fast failovers based on packet delay and is very prone to frequent unnecessary path switching.

let displayInlineWebRTCMetrics = !testCase.isVideoCallTest
let clearSciondCacheOnLaunch = false

let pauseLatencyProbingByDefault = testCase.isVideoCallTest || true
let pausePenaltiesByDefault = testCase != .videoFailoverRecovery && true

let useWhiteVideo = false

let caminandesVersion = 3 // One of the videos sent in the WebRTC call is caminandes. There are three parts of the video available. Select which one should be used
let bigChungusVersion = 2 // One of the videos sent in the WebRTC call is Big buck bunny. There are two versions available. Select which one should be used

let resultsBasePath = "/set/to/some/folder"

enum TestCase: String {
    case none
    case videoMetricsReport // Enable `useWhiteVideo` for low bw video test.
    case videoFailoverRecovery
    case videoRedundantTransmissionReport
    
    case latencyCompare
    case addedLatency
    case addedLoss
    case exactLatencyPlot
    
    var isVideoCallTest: Bool {
        switch self {
        case .addedLatency, .addedLoss, .latencyCompare, .exactLatencyPlot, .none:
            return false
        default:
            return true
        }
    }
}

let testCase = TestCase.none

// Should WebRTC audio/video be sent?
let videoEnabledDefault = testCase.isVideoCallTest ? (isCloud() ? true : false) : true
let audioEnabledDefault = testCase.isVideoCallTest ? false : true

func getWiFiIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
    if getifaddrs(&ifaddr) == 0 {
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee else { return nil }
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                
                // wifi = ["en0"]
                // wired = ["en2", "en3", "en4"]
                // cellular = ["pdp_ip0","pdp_ip1","pdp_ip2","pdp_ip3"]
                
                let name = String(cString: interface.ifa_name)
                if  name == "en0"  {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
    }
    
    return address
}

func isCloud() -> Bool {
    return getWiFiIPAddress() == "207.254.31.242"
}

func isPhone() -> Bool {
    #if os(iOS)
    return true
    #else
    return false
    #endif
}

enum SCIONAS: Int, CaseIterable {
    case cloud
    case hell
    case ethDirect
}

private func setUpEntryFor(AS: SCIONAS) -> (TopologyTemplate, String) {
    switch AS {
    case .cloud:
        return (SCIONLab_AWS_AP_Topology(), "192.168.64.2")
    case .hell:
        return (SCIONLab_AWS_Hell_AP_Topology(), "192.168.64.3")
    case .ethDirect:
        return (SCIONLab_ETH_Topology(), "0.0.0.0")
    }
}

let defaultScionSetupModel: [(TopologyTemplate, String)] = SCIONAS.allCases
    .sorted(by: { $0.rawValue < $1.rawValue })
    .map {
        setUpEntryFor(AS: $0)
    }

// Macincloud gets the n virginia AS, others get ETH
let defaultAS = {
    isCloud() ? SCIONAS.hell : (isPhone() ? SCIONAS.ethDirect : SCIONAS.ethDirect) }()

let defaultChatServer = {
    isCloud() ?  "17-ffaa:0:1102,1.1.1.1:1234" : "16-ffaa:1:f04,192.168.64.1:1234"
}()
