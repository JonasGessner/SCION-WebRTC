//
//  SCIONRelay.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 31.03.21.
//

import Foundation
import Combine
import CombineExt

// This file contains video call relays for SCION. These relays realize the relay connections (as they are called in the thesis report)
@_specialize(where C==SCIONMessage)
@_specialize(where C==Data)
fileprivate func isRTP<C: DataContainer>(_ source: C, handleRR: (UInt16, UInt16) -> Void) -> Bool {
    return source.data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
            print("RTCP demux check failed: No base buffer pointer")
            return false
        }
        
        return !rtcp_demux_is_rtcp(base, source.data.count, handleRR)
    }
}

protocol PacketTimingRelay: Relay {
    var lastReceievePacketDate: [[Date?]] { get }
}

extension Relay where Connection: SCIONUDPConnection, Message == SCIONMessage {
    func send(data: Data, through connection: Connection) throws {
        var rrBuffer: Data!
        
        _ = isRTP(data) { offset, length in
            var rr = Data(data[offset..<(offset + length)])
                
            rr.withUnsafeMutableBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }
                rtcp_remove_padding(base)
            }
            
            if rrBuffer == nil {
                rrBuffer = rr
            }
            else {
                rrBuffer += rr
            }
        }
        
        if rrBuffer != nil && isRTP(rrBuffer, handleRR: {_,_ in}) {
            _ = try connection.send(data: rrBuffer, path: connection.mirrorReplyPath)
        }
        
        _ = try connection.send(data: data)
    }
}

final class SCIONVideoCallRelayListener: PacketTimingRelay {
    let channels: [(ChannelType, SCIONUDPListener)]
    
    private(set) var connections: [[(SCIONUDPConnection, AnyPublisher<SCIONMessage, Error>)]]
    
    private(set) var lastReceievePacketDate: [[Date?]]
    
    let firstConnectionPublisher: [AnyPublisher<(SCIONUDPConnection, AnyPublisher<SCIONMessage, Error>), Never>]
    
    private var subs = Set<AnyCancellable>()
    
    let callQualityMonitors: [ChannelType: CallQualityMonitor]
    
    private let lock = NSLock()
    
    private let firstConnectionSubjects: [ReplaySubject<(Connection, AnyPublisher<Message, Error>), Never>]
    
    init(channelTypes: [ChannelType]) throws {
        connections = [[(SCIONUDPConnection, AnyPublisher<SCIONMessage, Error>)]](repeating: [], count: channelTypes.count)
        lastReceievePacketDate = [[Date]](repeating: [], count: channelTypes.count)

        // Use a different punisher per type of WebRTC channel, but share accross same channel type. Rationale: A path might be viable for audio transport but might completely break down on higher bandwidth video transport. In that case there should be no penalty applied to those paths when it comes to audio transport
        let webRTCPunishers = Dictionary(uniqueKeysWithValues: Set(channelTypes).map({ ($0, PathPenalizer(considerAsFailover: true)) }))
        
        // Prober is shared since all channels share the same e2e path options
        let latencyProber = LatencyProbingPathProcessor()
        
        let finalProcessors = webRTCPunishers.mapValues({ SequentialPathProcessor(processors: [HellPreprocessor(), latencyProber, $0]) })
        
        let penaltyListener = CallQualityMonitoringReceiveExtension()
        
        let receiveExtensions = SequentialReceiveExtension(receivers: [LatencyProbingReceiveExtension(), penaltyListener])
        
        // These are set on the first connection for each channel type. The exclusivity path punisher is used to make sure failovers happen to paths that share few links with the failed path. On failover to a new path upon receiving a path penalty notification, the path from which failover was performed is set as the exclusivity punisher's path
        let failoverExclusivityPunisher: [ChannelType: OverlapPathProcessor] = Dictionary(uniqueKeysWithValues: ChannelType.allCases.map({
            let pun = OverlapPathProcessor()
            return ($0, pun)
        }))
        
        let channels = channelTypes.map { type -> (ChannelType, SCIONUDPListener) in
            do {
                let server = try SCIONUDPListener(listeningOn: UInt16.random(in: 1025..<UInt16.max), pathProcessor: finalProcessors[type]!, receiveExtension: receiveExtensions, wantsToBeUsedForLatencyProbing: type == .audio)
                
                return (type, server)
            }
            catch {
                // TODO: handle port conflicts
                fatalError(error.localizedDescription)
            }
        }
        self.channels = channels
        
        let subjects = (0..<channelTypes.count).map { _ in
            ReplaySubject<(SCIONUDPConnection, AnyPublisher<SCIONMessage, Error>), Never>(bufferSize: 1)
        }
        
        let firstConnectionPublisher = subjects.map { $0.eraseToAnyPublisher() }
        self.firstConnectionPublisher = firstConnectionPublisher
        self.firstConnectionSubjects = subjects
        
        let monitors = Set(channelTypes).filter({ $0 == .video || $0 == .audio }).map({ type -> (ChannelType, CallQualityMonitor) in
            let firstConnectionPublishers = zip(channels, firstConnectionPublisher).filter({ $0.0.0 == type }).map { $0.1 }
            
            if type == .audio {
                return (type, AudioCallQualityMonitor(channelType: type, connections: firstConnectionPublishers.map({ $0.map({ $0.0 }).eraseToAnyPublisher() }), noncriticalPenaltiesGracePeriodAfterPathSwitch: 15))
            }
            else {
                assert(type == .video)
                return (type, VideoCallQualityMonitor(channelType: type, connections: firstConnectionPublishers.map({ $0.map({ $0.0 }).eraseToAnyPublisher() }), noncriticalPenaltiesGracePeriodAfterPathSwitch: 30))
            }
        })
        
        monitors
            .compactMap({ $0.1 as? AudioCallQualityMonitor })
            .forEach({
                $0.referenceVideoMonitor = monitors.compactMap({ $0.1 as? VideoCallQualityMonitor }).first
        })
        
        callQualityMonitors = Dictionary(uniqueKeysWithValues: monitors)
        
        // Used for exclusivity punishers
        var existingConns: [ChannelType: [SCIONUDPConnection]] = Dictionary(uniqueKeysWithValues: ChannelType.allCases.map({ ($0, []) }))
        var existingExclusivityPunishers: [SCIONUDPConnection: OverlapPathProcessor] = [:]
        
        func penalize(_ path: SCIONPath, weight: Double, channelType: ChannelType) {
            print("Applying penalty to path \(path.canonicalFingerprintShortWithTCInfo) for channel type \(channelType): \(weight)")
            
            guard var oldValue = webRTCPunishers[channelType]?.punishmentWeight(for: path) else {
                print("Penalty entry not found")
                return
            }
            
            // When we receive a positive penalty (meaning bad path) we undo any negative penalties (meaning good path) before applying the penalty
            if weight > 0 {
                oldValue = max(0, oldValue)
            }
            
            let newValue = oldValue + weight
            let bounded = max(min(newValue, 10), -0.2)
            
            guard bounded != oldValue else { return }
            
            webRTCPunishers[channelType]?.mutating(by: { w in
                var mut = w
                mut[path] = bounded
                return mut
            }, countsAsFailover: weight > 0)
        }
        
        penaltyListener.publisher.sink { [weak self] notification in
            guard let self = self else { return }
            
            if notification.pathFingerprint == PenaltyNotification.broadcastPenaltyIdentifier {
                let allConns = zip(channels, self.connections).filter({ $0.0.0 == notification.channelType }).flatMap({ $0.1 }).map({ $0.0 })
                
                let currentPaths = allConns.compactMap({ $0.effectivePath })
                
                print("Handling broadcast penalty")
                
                currentPaths.forEach({
                    penalize($0, weight: notification.weight, channelType: notification.channelType)
                })
            }
            else {
                guard let matchingPath = zip(channels, self.connections).filter({ $0.0.0 == notification.channelType }).first?.1.first?.0.paths.first(where: { notification.pathFingerprint == $0.canonicalFingerprintShort }) else {
                    print("Path for penalty not found")
                    return
                }

                penalize(matchingPath, weight: notification.weight, channelType: notification.channelType)
            }
        }
        .store(in: &subs)
        
        for (index, (subject, (channelType, server))) in zip(firstConnectionSubjects, channels).enumerated() {
            var firstConnection = true
            server.accept { [weak self] pun in
                var p: PathProcessor = pun
                
                self?.lock.lock()
                for existing in existingConns[channelType]! {
                    let exclusivityPunisher = existingExclusivityPunishers[existing] ?? OverlapPathProcessor(referenceConnection: existing)
                    
                    if existingExclusivityPunishers[existing] == nil {
                        existingExclusivityPunishers[existing] = exclusivityPunisher
                    }
                    
                    p = p.joinFlat(with: exclusivityPunisher)
                }
                
                p = p.joinFlat(with: failoverExclusivityPunisher[channelType]!)
                
                return (p, { newConnection in
                    newConnection.map { existingConns[channelType]! += [$0] }
                    self?.lock.unlock()
                })
            }
            .sink { [weak self, weak subject] newConnection in
                guard let self = self else { return }
                
                newConnection.mirrorReplyPathFilter = {
                    return isRTP($0, handleRR: {_,_ in})
                }
                
                self.lock.lock()
                let connectionIndex = self.lastReceievePacketDate[index].count
                self.lastReceievePacketDate[index].append(nil)
                self.lock.unlock()
                
                let pub = newConnection.listen()
                    .setFailureType(to: Error.self)
                    .handleOutput({ _ in
                        self.lock.lock()
                        self.lastReceievePacketDate[index][connectionIndex] = Date()
                        self.lock.unlock()
                    })
                    .share()
                    .eraseToAnyPublisher()
                
                if firstConnection {
                    firstConnection = false
                    if let s = subject {
                        s.send((newConnection, pub))
                        s.send(completion: .finished)
                    }
                }
                
                self.lock.lock()
                self.connections[index].append((newConnection, pub))
                
                newConnection.failoverPublisher.sink { old, new in
                    let refPaths = failoverExclusivityPunisher[channelType]!.referencePaths
                    
                    guard old != refPaths.first?.0 else {
                        print("Failover to path that is already the first reference path")
                        return
                    }
                    
                    print("Connection for channel \(channelType) failed over from \(old.canonicalFingerprintShortWithTCInfo) to \(new.canonicalFingerprintShortWithTCInfo)")
                    
                    // Keep the last three failovers here and weigh them by 0.4, 0.2 and 0.1
                    let newRefPaths = CollectionOfOne((old, 1)) + refPaths.prefix(2).map({ $0.0 }).enumerated().map({ ($0.element, Double(2 - $0.offset) * 0.3) })
                    
                    failoverExclusivityPunisher[channelType]!.referencePaths = newRefPaths
                }
                .store(in: &self.subs)
                
                self.lock.unlock()
            }
            .store(in: &subs)
        }
    }
    
    func close() {
        channels.forEach({
            $0.1.close()
        })
        firstConnectionSubjects.forEach({
            $0.send(completion: .finished)
        })
        connections.flatMap({ $0 }).forEach({ con, _ in
            con.close()
        })
    }
    
    deinit {
        close()
    }
}

// MARK: - For tests only
fileprivate var allTestResults: [TestSnapshot] = []
fileprivate let currentTestTimestamp = Date().timeIntervalSince1970
// MARK: -

final class SCIONVideoCallRelayClient: PacketTimingRelay {
    let channels: [(ChannelType, SCIONUDPConnection)]
    let connections: [[(SCIONUDPConnection, AnyPublisher<SCIONMessage, Error>)]]
    
    private(set) var lastReceievePacketDate: [[Date?]]
    
    let firstConnectionPublisher: [AnyPublisher<(SCIONUDPConnection, AnyPublisher<SCIONMessage, Error>), Never>]
    
    let callQualityMonitors: [ChannelType: CallQualityMonitor]
    
    private var subs = Set<AnyCancellable>()
    
    private let lock = NSLock()
    
    init(serverInfo: RelayServerInfo) throws {
        let channelTypes = Set(serverInfo.endpoints.map({ $0.channelType }))
        
        let webRTCPunishers = Dictionary(uniqueKeysWithValues: channelTypes.map({ ($0, PathPenalizer(considerAsFailover: true)) }))
        
        // Prober is shared since all channels share the same e2e path options
        let latencyProber = LatencyProbingPathProcessor()
        
        let finalProcessors = webRTCPunishers.mapValues({ SequentialPathProcessor(processors: [HellPreprocessor(), latencyProber, $0]) })
        
        let penaltyListener = CallQualityMonitoringReceiveExtension()
        
        let receiveExtensions = SequentialReceiveExtension(receivers: [LatencyProbingReceiveExtension(), penaltyListener])
        
        // Used for exclusivity punishers
        var existingConns: [ChannelType: [SCIONUDPConnection]] = Dictionary(uniqueKeysWithValues: ChannelType.allCases.map({ ($0, []) }))
        var existingExclusivityPunishers: [SCIONUDPConnection: OverlapPathProcessor] = [:]
        
        // These are set on the first connection for each channel type. The exclusivity path punisher is used to make sure failovers happen to paths that share few links with the failed path. On failover to a new path upon receiving a path penalty notification, the path from which failover was performed is set as the exclusivity punisher's path
        let failoverExclusivityPunisher: [ChannelType: OverlapPathProcessor] = Dictionary(uniqueKeysWithValues: ChannelType.allCases.map({
            let pun = OverlapPathProcessor()
            return ($0, pun)
        }))
        
        var subs = Set<AnyCancellable>()
        
        let channels: [(ChannelType, SCIONUDPConnection)] = try serverInfo.endpoints.map { endpoint in
            // Server address is ISD-AS-IP. Add port number for each channel
            let addressString = serverInfo.serverAddress.description + ":\(endpoint.port)"
            
            var err: Error!
            for attempt in 0..<5 {
                do {
                    var p: PathProcessor = finalProcessors[endpoint.channelType]!
                    
                    for existing in existingConns[endpoint.channelType]! {
                        let exclusivityPunisher = existingExclusivityPunishers[existing] ?? OverlapPathProcessor(referenceConnection: existing)
                        
                        if existingExclusivityPunishers[existing] == nil {
                            existingExclusivityPunishers[existing] = exclusivityPunisher
                        }
                        
                        p = p.joinFlat(with: exclusivityPunisher)
                    }
                    
                    p = p.joinFlat(with: failoverExclusivityPunisher[endpoint.channelType]!)
                    
                    let connection = try SCIONUDPConnection(clientConnectionTo: addressString, pathProcessor: p, receiveExtension: receiveExtensions, wantsToBeUsedForLatencyProbing: endpoint.channelType == .audio)
                    
                    connection.failoverPublisher.sink { old, new in
                        let refPaths = failoverExclusivityPunisher[endpoint.channelType]!.referencePaths
                        
                        guard old != refPaths.first?.0 else { return }
                        
                        print("Connection for channel \(endpoint.channelType) failed over from \(old.canonicalFingerprintShortWithTCInfo) to \(new.canonicalFingerprintShortWithTCInfo)")
                        
                        // Keep the last three failovers here and weigh them by 0.4, 0.2 and 0.1
                        let newRefPaths = CollectionOfOne((old, 1)) + refPaths.prefix(2).map({ $0.0 }).enumerated().map({ ($0.element, Double(2 - $0.offset) * 0.3) })
                        
                        failoverExclusivityPunisher[endpoint.channelType]!.referencePaths = newRefPaths
                    }
                    .store(in: &subs)
                    
                    existingConns[endpoint.channelType]! += [connection]
                    
                    connection.mirrorReplyPathFilter = {
                        return isRTP($0, handleRR: {_,_ in})
                    }
                    
                    return (endpoint.channelType, connection)
                }
                catch {
                    err = error
                    // TODO: handle port conflicts
                    print("Attempt \(attempt) to create connection failed with \(error). Trying again")
                }
            }
            
            throw err
        }
        
        func penalize(_ path: SCIONPath, weight: Double, channelType: ChannelType) {
            print("Applying penalty to path \(path.canonicalFingerprintShortWithTCInfo) for channel type \(channelType): \(weight)")
            
            guard var oldValue = webRTCPunishers[channelType]?.punishmentWeight(for: path) else {
                print("Penalty entry not found")
                return
            }
            
            // When we receive a positive penalty (meaning bad path) we undo any negative penalties (meaning good path) before applying the penalty
            if weight > 0 {
                oldValue = max(0, oldValue)
            }
            
            let newValue = oldValue + weight
            let bounded = max(min(newValue, 10), -0.2)
            
            guard bounded != oldValue else { return }
            
            webRTCPunishers[channelType]?.mutating(by: { w in
                var mut = w
                mut[path] = bounded
                return mut
            }, countsAsFailover: weight > 0)
        }
        
        penaltyListener.publisher.sink { notification in
            if notification.pathFingerprint == PenaltyNotification.broadcastPenaltyIdentifier {
                let allConns = channels.filter({ $0.0 == notification.channelType }).map({ $1 })
                
                let currentPaths = allConns.compactMap({ $0.effectivePath })
                
                print("Handling broadcast penalty")
                
                currentPaths.forEach({
                    penalize($0, weight: notification.weight, channelType: notification.channelType)
                })
            }
            else {
                guard let matchingPath = channels.filter({ $0.0 == notification.channelType }).first?.1.paths.first(where: { notification.pathFingerprint == $0.canonicalFingerprintShort }) else {
                    print("Path for penalty not found")
                    return
                }
                
                penalize(matchingPath, weight: notification.weight, channelType: notification.channelType)
            }
        }
        .store(in: &subs)
        
        self.subs = subs
        self.channels = channels
        
        lastReceievePacketDate = channels.map({ _ in
            [nil]
        })

        connections = channels.map {
            let pub = $0.1.listen()
                .setFailureType(to: Error.self)
                .share()
                .eraseToAnyPublisher()
            
            return [($0.1, pub)]
        }
        
        let firstConnectionPublisher = connections.map { Just($0[0]).eraseToAnyPublisher() }
        self.firstConnectionPublisher = firstConnectionPublisher
        
        let monitors = channelTypes.filter({ $0 == .video || $0 == .audio }).map({ type -> (ChannelType, CallQualityMonitor) in
            let firstConnectionPublishers = zip(channels, firstConnectionPublisher).filter({ $0.0.0 == type }).map { $0.1 }
            
            if type == .audio {
                return (type, AudioCallQualityMonitor(channelType: type, connections: firstConnectionPublishers.map({ $0.map({ $0.0 }).eraseToAnyPublisher() }), noncriticalPenaltiesGracePeriodAfterPathSwitch: 15))
            }
            else {
                assert(type == .video)
                
                let m = VideoCallQualityMonitor(channelType: type, connections: firstConnectionPublishers.map({ $0.map({ $0.0 }).eraseToAnyPublisher() }), noncriticalPenaltiesGracePeriodAfterPathSwitch: 30)
                
                if testCase.isVideoCallTest {
                    shell("ssh -t administrator@207.254.31.242 \"ssh -t root@192.168.64.2 './tc.sh config 0 0'\"").forceSuccess()
                    
                    func doBW(_ bw: Int) {
                        let tcGroup = Int(m.currentPaths[0].tcIdentifier!.components(separatedBy: " ").last!)!
                        let shellResult = shell("ssh -t administrator@207.254.31.242 \"ssh -t root@192.168.64.2 \\\"./tc.sh \(tcGroup) '' 'rate \(bw)kbit limit 10000 burst 1000kb'\\\"\"").forceSuccess()
                        
                        let str = String(data: shellResult, encoding: .utf8)!
                        
                        print(str)
                    }
                    
                    m.testTick = { tick, stats in
                        if tick == 21 {
                            if testCase == .videoMetricsReport || testCase == .videoRedundantTransmissionReport || stats.penaltyTimes.isEmpty {
                                doBW(1500)
                            }
                        }
                        else if tick == 31 {
                            if testCase == .videoMetricsReport || testCase == .videoRedundantTransmissionReport || stats.penaltyTimes.isEmpty {
                                doBW(1000)
                            }
                        }
                        else if tick == 41 {
                            if testCase == .videoMetricsReport || testCase == .videoRedundantTransmissionReport || stats.penaltyTimes.isEmpty {
                                doBW(700)
                            }
                        }
                        else if tick == 51 {
                            if testCase == .videoMetricsReport || testCase == .videoRedundantTransmissionReport || stats.penaltyTimes.isEmpty {
                                doBW(400)
                            }
                        }
                        else if tick == 61 {
                            if testCase == .videoMetricsReport || testCase == .videoRedundantTransmissionReport || stats.penaltyTimes.isEmpty {
                                doBW(200)
                            }
                        }
                        else if tick == 81 {
                            allTestResults.append(stats)
                            
                            let encoder = JSONEncoder()
                            encoder.dateEncodingStrategy = .millisecondsSince1970
                            let encoded = try! encoder.encode(allTestResults)
                            try! encoded.write(to: URL(fileURLWithPath: "\(resultsBasePath)/result-\(testCase.rawValue)-\(currentTestTimestamp).json"))
                            print(String(data: encoded, encoding: .utf8)!)
                            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "hangup__"), object: nil)
                            
                            shell("ssh -t administrator@207.254.31.242 \"ssh -t root@192.168.64.2 './tc.sh config 0 0'\"").forceSuccess()
                        }
                        print("Yoo test \(tick)")
                    }
                }
                
                return (type, m)
            }
        })
        
        monitors
            .compactMap({ $0.1 as? AudioCallQualityMonitor })
            .forEach({
                $0.referenceVideoMonitor = monitors.compactMap({ $0.1 as? VideoCallQualityMonitor }).first
            })
        
        callQualityMonitors = Dictionary(uniqueKeysWithValues: monitors)
        
        connections.map({ $0[0].1 }).enumerated().forEach { index, element in
            element.sink(receiveCompletion: {_ in}, receiveValue: { _ in
                self.lock.lock()
                self.lastReceievePacketDate[index][0] = Date()
                self.lock.unlock()
            })
            .store(in: &self.subs)
        }
    }
    
    func close() {
        channels.forEach({
            $0.1.close()
        })
    }
    
    deinit {
        close()
    }
}
