//
//  VideoCallStatsView.swift
//  SCIONTest-macOS
//
//  Created by Jonas Gessner on 14.06.21.
//

import Foundation
import SwiftUI

#if os(macOS)
struct StatsView: NSViewRepresentable {
    typealias NSViewType = NSTextView
    
    let texts: [(String, [String])]
    
    func makeNSView(context: Context) -> NSViewType {
        let v = NSTextView()
        v.isEditable = false
        v.backgroundColor = NSColor.clear
        return v
    }
    
    func updateNSView(_ nsView: NSTextView, context: Context) {
        nsView.textStorage?.setAttributedString(texts.map { title, values -> NSAttributedString in
            let titleString = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
            values.forEach({
                titleString.append(NSAttributedString(string: $0 + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
            })
            
            return titleString
        }
        .reduce(NSMutableAttributedString(), {
            if $0.length > 0 {
                $0.append(NSAttributedString(string: "\n"))
            }
            $0.append($1)
            return $0
        }))
    }
}
#endif

// Leaks memory like crazy on macOS. On every redraw all NSViews used are leaked. WTF?
struct VideoCallStatsView: View {
    #if GATHER_RELAY_FREEZE_STATS
    @ObservedObject private var relayStats = RelayStatistics.shared
    #endif
    
    let detailed: Bool

    let lastPenalties: [(ChannelType, Penalty, Date)]
    
    private func relayStrings(for channelType: ChannelType) -> [String] {
        #if GATHER_RELAY_FREEZE_STATS
        let audioRelays = RelayStatistics.shared.stats.filter({ $0.0.1 == channelType }).map({ ($0.0.0, $0.1) })
        
        return audioRelays.map({ (relay: AnyObject, report: RelayStatistics.Report) -> String in
            if relay is SCIONVideoCallRelayClient || relay is SCIONVideoCallRelayListener {
                return "Receiver relay freezes: \(report.freezes.map({ $0.duration }))"
                //                return "Receiver relay bandwidth: \(report.averageSpeed)"
            }
            else {
                return "Sender relay freezes: \(report.freezes.map({ $0.duration }))"
                //                return "Sender relay bandwidth: \(report.averageSpeed)"
            }
        })
        #else
        return []
        #endif
    }
    
    var videoRelayStrings: [String] {
        return relayStrings(for: .video)
    }
    
    var audioRelayStrings: [String] {
        return relayStrings(for: .audio)
    }
    
    func strings(_ report: StatisticsReport) -> [(String, [String])] {
        var arr = [(String, [String])]()
        
        let subA: StatisticsReportAudio = report.audio
        arr.append(("Audio Stats",
                    detailed ?
                        [
                            "Out Packets Lost \(subA.remoteInboundRTP.packetsLost) / \(subA.remoteInboundRTP.fractionLost * 100)%",
                            "RTT \(subA.remoteInboundRTP.roundTripTime)s / \(subA.remoteInboundRTP.roundTripTimeMeasurements) Measurements",
                            "Jitter \(subA.remoteInboundRTP.jitter)",
                            "Interruptions/total dur \(subA.receiverTrack.interruptionCount)/\(subA.receiverTrack.totalInterruptionDuration)",
                            "Concealments \(subA.receiverTrack.concealmentEvents)",
                            "B Sent/Received \(formatBytes(subA.transport.bytesSent))/\(formatBytes(subA.transport.bytesReceived))",
                            "Retransmitted B/Pckts \(formatBytes(subA.outboundRTP.retransmittedBytesSent))/\(subA.outboundRTP.retransmittedPacketsSent)"
                        ] + audioRelayStrings :
                        [
                            "Out packets lost:\t\t  \(subA.remoteInboundRTP.packetsLost) / \(subA.remoteInboundRTP.fractionLost * 100)%",
                            "In freeze count/total dur:\t  \(subA.receiverTrack.interruptionCount) / \(subA.receiverTrack.totalInterruptionDuration)"
                        ]
        ))
    
        let sub: StatisticsReportVideo = report.video
        arr.append(("Video Stats",
                    detailed ?
                        [
                            "Packets Lost \(sub.remoteInboundRTP.packetsLost) / \(sub.remoteInboundRTP.fractionLost * 100)%",
                            "RTT \(sub.remoteInboundRTP.roundTripTime)s / \(sub.remoteInboundRTP.roundTripTimeMeasurements) Measurements",
                            "Jitter \(sub.remoteInboundRTP.jitter)",
                            "Freezes/total freeze dur \(sub.receiverTrack.freezeCount)/\(sub.receiverTrack.totalFreezesDuration)",
                            "Frames Received/Decoded/Dropped \(sub.receiverTrack.framesReceived)/\(sub.receiverTrack.framesDecoded)/\(sub.receiverTrack.framesDropped)",
                            "Incoming Resolution \(sub.receiverTrack.frameWidth ?? 0)x\(sub.receiverTrack.frameHeight ?? 0)",
                            "Frames Sent \(sub.senderTrack.framesSent)",
                            "Outgoing Resolution \(sub.senderTrack.frameWidth)x\(sub.senderTrack.frameHeight)",
                            "FPS In/Out \(sub.inboundRTP.framesPerSecond ?? 0)/\(sub.outboundRTP.framesPerSecond ?? 0)",
                            "Quality changes \(sub.outboundRTP.qualityLimitationResolutionChanges)",
                            "FIRs \(sub.outboundRTP.firCount)",
                            "NACKs \(sub.outboundRTP.nackCount)",
                            "Quality reason \(sub.outboundRTP.qualityLimitationReason)",
                            "B Sent/Received \(formatBytes(sub.transport.bytesSent))/\(formatBytes(sub.transport.bytesReceived))",
                            "Retransmitted B/Pckts \(formatBytes(sub.outboundRTP.retransmittedBytesSent))/\(sub.outboundRTP.retransmittedPacketsSent)"
                        ] + videoRelayStrings :
                        [
                            "Out packets lost:\t\t\t\(sub.remoteInboundRTP.packetsLost) / \(sub.remoteInboundRTP.fractionLost * 100)%",
                            "In freeze count/total dur:\t\t\(sub.receiverTrack.freezeCount) / \(sub.receiverTrack.totalFreezesDuration)",
                            "Resolution in/out:\t\t\t\(sub.receiverTrack.frameWidth ?? 0)x\(sub.receiverTrack.frameHeight ?? 0) / \(sub.senderTrack.frameWidth)x\(sub.senderTrack.frameHeight)",
                            "FPS in/out:\t\t\t\t\(sub.inboundRTP.framesPerSecond ?? 0) / \(sub.outboundRTP.framesPerSecond ?? 0)",
                            "Out quality limitation reason:\t\(sub.outboundRTP.qualityLimitationReason)"
                        ]
        ))
        
        if !lastPenalties.isEmpty {
            let rel = RelativeDateTimeFormatter()
            rel.dateTimeStyle = .named
            
            arr.append(("Sent Penalties/Rewards",
                        lastPenalties.map({ channel, pen, date in
                            "\(channel.rawValue.capitalized): \(pen.value). \(pen.description)\(pen.critical ? " (Critical)" : ""). \(rel.localizedString(for: date, relativeTo: Date()))"
                        })
            ))
        }
        
        return arr
    }
    
    #if !os(macOS)
    @ViewBuilder
    func reportView(_ report: StatisticsReport) -> some View {
        let strs = strings(report)
        let Ided = strs.map({ ($0, $0.1.hashValue) })
        ForEach(Ided, id: \.1) { pair, _ in
            Text(pair.0).font(.subheadline)
            ForEach(pair.1, id: \.self) { stat in
                Text(stat)
            }
        }
    }
    #endif
    
    @State var report: StatisticsReport?
    
    var body: some View {
        Group {
            if let report = self.report {
                #if os(macOS)
                StatsView(texts: strings(report))
                #else
                reportView(report)
                #endif
            }
        }
        // For some reason putting the onReceive on `self` results in an infinite loop
        .onReceive(VideoChatSession.shared.reportPublisher) { report in
            self.report = report
        }
    }
}
