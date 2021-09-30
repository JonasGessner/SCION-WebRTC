//
//  CallQualityMonitor.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 13.05.21.
//

import Foundation
import Combine
import CombineExt

/// Mark: - Penalties that are sent over the wire

fileprivate var pathPenaltySeqID: UInt32 = 1
fileprivate let pathPenaltySeqIDLock = NSLock()

fileprivate func nextPathPenaltySeqID() -> UInt32 {
    pathPenaltySeqIDLock.lock()
    
    let val = pathPenaltySeqID
    pathPenaltySeqID += 1
    
    pathPenaltySeqIDLock.unlock()
    
    return val
}

struct Penalty {
    let value: Double
    let critical: Bool
    let description: String
}

struct PenaltyNotification: Equatable, Hashable {
    let weight: Double
    let channelType: ChannelType
    let pathFingerprint: String
    
    static let broadcastPenaltyIdentifier = "--"
}

struct PenaltyNotificationBatch: Equatable, Hashable {
    let seqID: UInt32
    let penalties: [PenaltyNotification]
}

extension PenaltyNotification: Codable {}
extension PenaltyNotificationBatch: Codable {}

/// Mark: -

fileprivate protocol CallMetric {
    func purge(anythingOlderThan timeInterval: TimeInterval)
}

/// Keeps track of a certain metric over time and can be used to determine when certain thresholds are crossed
final class TimedMetric<T: Numeric>: CallMetric {
    private(set) var entries = [(Date, T)]()
    
    func add(entry: T) {
        entries.append((Date(), entry))
    }
    
    private func entriesNeverThan(_ timeInterval: TimeInterval) -> ArraySlice<(Date, T)>  {
        let now = Date()
        let truncated = entries.drop(while: { now.timeIntervalSince($0.0) > timeInterval })
        return truncated
    }
    
    func purge(anythingOlderThan timeInterval: TimeInterval) {
        if timeInterval == 0 {
            entries.removeAll()
            return
        }
        
        entries = Array(entriesNeverThan(timeInterval))
    }
    
    var range: TimeInterval {
        guard let first = entries.first?.0 else {
            return 0
        }
        
        return Date().timeIntervalSince(first)
    }
    
    private func sum(over timeInterval: TimeInterval, relative: Bool) -> (Int, TimeInterval, T) {
        let relevant = entriesNeverThan(timeInterval)
        let avg = relevant.map({ $0.1 }).reduce(0, +)
        let finalAvg = relative ? avg - (relevant.first?.1 ?? 0) : avg
        
        return (relevant.count, relevant.last?.0.timeIntervalSince(relevant.first?.0 ?? Date()) ?? 0, finalAvg)
    }
    
    func sum(over timeInterval: TimeInterval, relative: Bool) -> T {
        return sum(over: timeInterval, relative: relative).2
    }
    
    func difference(over timeInterval: TimeInterval, operator op: (T) -> Bool, _ log: String? = nil) -> Bool {
        if differenceWithTime(over: timeInterval, operator: { _, v in
            return op(v)
        }) {
            if let log = log {
                print(log)
            }
            return true
        }
        else {
            return false
        }
    }
    
    /// Starting from the last added element this function goes backwards in the entries as long as the predicate is satisfied, returning the duration between the earliest matching element and the last element.
    func duration(satisfying predicate: (T) -> Bool) -> TimeInterval {
        guard let last = entries.last
              /* let lastSatisfying = entries.reversed().last(where: { predicate($1) }) this is Theta(n) */
        else {
            return 0
        }
        
        let lastSatisfyingIndex = entries.reversed().firstIndex(where: { !predicate($1) })
            .map({ entries.count - $0 }).map({ min($0 + 1, entries.count - 1) }) ?? entries.startIndex
        
        let lastSatisfying = entries[lastSatisfyingIndex]
        
        return last.0.timeIntervalSince(lastSatisfying.0)
    }
    
    func getDifferenceWithTime(overCount count: Int) -> (TimeInterval, T) {
        guard count > 0, !entries.isEmpty else { return (0, 0) }
        
        let rangeStart = entries[max((entries.count - count), 0)]
        
        let diff = entries.last!.1 - rangeStart.1
        
        return (entries.last!.0.timeIntervalSince(rangeStart.0), diff)
    }
    
    func getDifference(overCount count: Int) -> T {
        return getDifferenceWithTime(overCount: count).1
    }
    
    func getDifferenceWithTime(over timeInterval: TimeInterval) -> (TimeInterval, T) {
        guard timeInterval > 0, range >= timeInterval else { return (0, 0) }
        
        let ref = Date(timeIntervalSinceNow: -timeInterval)
        let rangeStart = entries.last(where: { $0.0 < ref }) ?? entries[0]
        
        let diff = entries.last!.1 - rangeStart.1
        
        return (entries.last!.0.timeIntervalSince(rangeStart.0), diff)
    }
    
    func getDifference(over timeInterval: TimeInterval) -> T {
        return getDifferenceWithTime(over: timeInterval).1
    }
    
    func differenceWithTime(over timeInterval: TimeInterval, operator op: (TimeInterval, T) -> Bool) -> Bool {
        guard timeInterval > 0, range >= timeInterval else { return false }
        
        let (time, diff) = getDifferenceWithTime(over: timeInterval)
        
        return op(time, diff)
    }
    
    func calculateAverage(over timeInterval: TimeInterval, relative: Bool, timeAverage: Bool = false) -> Double where T: BinaryFloatingPoint  {
        guard timeInterval > 0, range >= timeInterval else { return 0 }
        
        let (count, time, sum) = sum(over: timeInterval, relative: relative)
        
        if count == 0 || (timeAverage && count == 1) {
            return 0
        }
        
        let avg = Double(sum) / (timeAverage ? Double(time) : Double(count))
        
        return avg
    }
    
    func calculateAverage(over timeInterval: TimeInterval, relative: Bool, timeAverage: Bool = false) -> Double where T: BinaryInteger  {
        guard timeInterval > 0, range >= timeInterval else { return 0 }
        
        let (count, time, sum) = sum(over: timeInterval, relative: relative)
        
        if count == 0 || (timeAverage && count == 1) {
            return 0
        }
        
        let avg = Double(sum) / (timeAverage ? Double(time) : Double(count))
        
        return avg
    }
    
    func average(over timeInterval: TimeInterval, relative: Bool, operator op: (Double) -> Bool) -> Bool where T: BinaryInteger {
        guard timeInterval > 0, range >= timeInterval else { return false }
        
        let avg = calculateAverage(over: timeInterval, relative: relative, timeAverage: false)
        
        return op(avg)
    }
    
    func average(over timeInterval: TimeInterval, relative: Bool, operator op: (Double) -> Bool) -> Bool where T: BinaryFloatingPoint {
        guard timeInterval > 0, range >= timeInterval else { return false }
        
        let avg = calculateAverage(over: timeInterval, relative: relative, timeAverage: false)
        
        return op(avg)
    }
}

/// Call quality monitor receives WebRTC metrics every second and decides when to apply penalties
class CallQualityMonitor {
    let channelType: ChannelType
    
    fileprivate private(set) var lastPenalized = [SCIONPath]()
    
    static let penaltyQueue = DispatchQueue(label: "path penalty", qos: .utility, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    
    private var noNonCriticalPenaltiesUntil = Date.distantPast
    
    // Whether penalties should actually be sent out
    static var sendingEnabled = !pausePenaltiesByDefault
    
    private var currentPathsToken = UUID() {
        didSet {
            repeatPenaltyCount = 0
            lastPenalizedTime = Date.distantPast
        }
    }
    private(set) var currentPaths = [SCIONPath]() {
        didSet {
            guard currentPaths != oldValue else {
                return
            }
            print("Current incoming paths changed for call quality monitor type \(channelType) from \(oldValue.map({ $0.canonicalFingerprintShortWithTCInfo }).joined(separator: ", ")) to \(currentPaths.map({ $0.canonicalFingerprintShortWithTCInfo }).joined(separator: ", "))")
            
            // Old value is empty the first time that paths are set. We only want to reset stuff when switching from a path to another
            if !oldValue.isEmpty {
                currentPathsToken = UUID()
                resetStats()

                // Reset shortly after to make sure no late-arriving metrics from when the previous paths were used affect the current path quality estimate
                CallQualityMonitor.penaltyQueue.asyncAfter(deadline: .now() + 1) {
                    self.resetStats()
                }
            }
        }
    }
    
    fileprivate func resetStats() {
        Mirror(reflecting: self).children
            .compactMap({ $0.value as? CallMetric })
            .forEach({ $0.purge(anythingOlderThan: 0) })
    }
    
    private var connection: SCIONUDPConnection?
    
    private var subs = Set<AnyCancellable>()
    
    private let noncriticalPenaltiesGracePeriodAfterPathSwitch: TimeInterval
    
    /// noncriticalPenaltiesGracePeriodAfterPathSwitch: Penalties marked as non critical are ignored for `noncriticalPenaltiesGracePeriodAfterPathSwitch`s after the last path switch. This is there to avoid frantic repeated path switching. The grace period should give WebRTC some time to recover and get its shit together after a switch away from a horrible path. If only the bandwidth estimator could be easily influenced....
    fileprivate init(channelType: ChannelType, connections: [AnyPublisher<SCIONUDPConnection, Never>], noncriticalPenaltiesGracePeriodAfterPathSwitch: TimeInterval) {
        self.channelType = channelType
        self.noncriticalPenaltiesGracePeriodAfterPathSwitch = noncriticalPenaltiesGracePeriodAfterPathSwitch

        Publishers.MergeMany(connections)
            .collect()
            .sink(receiveValue: { [weak self] (connections: [SCIONUDPConnection]) in
                guard let self = self else { return }

                self.connection = connections.min(by: { $0.fullPathProcessor.processors.count < $1.fullPathProcessor.processors.count })
                
                connections
                    .map({ $0.$mirrorReplyPath })
                    .combineLatest()
                    .map({ $0.compactMap({ $0?.path }) })
                    .assign(to: \.currentPaths, on: self, ownership: .weak)
                    .store(in: &self.subs)
            })
            .store(in: &subs)
    }
    
    private var lastPenalizedToken: UUID? {
        didSet {
            if lastPenalizedToken != oldValue {
                repeatPenaltyCount = 0
                lastPenalizedTime = Date.distantPast
            }
        }
    }
    private var repeatPenaltyCount = 0
    private var lastPenalizedTime = Date.distantPast
    
    fileprivate func apply(penalties __p: [Penalty], criticalGracePeriod: TimeInterval? = nil) {
        let penalties: [Penalty]
        if Date() < noNonCriticalPenaltiesUntil {
            penalties = __p.filter({ $0.critical })
        }
        else {
            penalties = __p
        }
        
        guard !penalties.isEmpty else {
            lastPenalized = []
            return
        }
        
        guard CallQualityMonitor.sendingEnabled else {
            lastPenalized = []
            return
        }
        
        guard let connection = self.connection else {
            print("Cant apply penalty because there is no connection to use as notifier")
            lastPenalized = []
            return
        }
        
        let punishment = penalties.reduce(0, { $0 + $1.value })
        
        NotificationCenter.default.post(name: NSNotification.Name("PathPenalty"), object: nil, userInfo: ["penalties": penalties, "channel": channelType])
        
        if punishment < 0 {
            resetStats()
            repeatPenaltyCount = 0
        }
        else {
            if currentPathsToken == lastPenalizedToken,
               Date().timeIntervalSince(lastPenalizedTime) < 5 {
                repeatPenaltyCount += 1
            }
            else {
                repeatPenaltyCount = 0
            }
        }
        
        lastPenalizedToken = currentPathsToken
        lastPenalizedTime = Date()
        
        if repeatPenaltyCount >= 5 {
            print("Not sending penalty: Already at 5 repeats")
            lastPenalized = []
            return
        }
        
        lastPenalized = currentPaths
        
        let seqID = nextPathPenaltySeqID()

        let broadcast = repeatPenaltyCount > 1
        
        NSLog("Monitor for channel \(channelType) applying penalty \(punishment) to \(broadcast ? "BROADCAST" : currentPaths.map({ $0.canonicalFingerprintShortWithTCInfo }).joined(separator: ", ")). Repeat penalty \(repeatPenaltyCount). Seqid \(seqID)")

        print("Penalties: \(penalties)")
        // After 2 or more repeat penalties we no longer penalize the exact path – we specify the `broadcastPenaltyIdentifier` which signals to the receiver to simply penalize whichever paths it is currently using. Why? The sender might have switched to different paths that are down, so we never found out about these new paths. We would still be penalizing the old paths, the penalties of which have no effect on the new paths. So instead we simply tell the other side to penalize the paths it is currently using, without knowing which these are
        let notifications: [PenaltyNotification] =
            broadcast ?
                [PenaltyNotification(weight: punishment, channelType: channelType, pathFingerprint: PenaltyNotification.broadcastPenaltyIdentifier)]
                :
                currentPaths.map({
                    return PenaltyNotification(weight: punishment, channelType: channelType, pathFingerprint: $0.canonicalFingerprintShort)
                })
             
        let batch = PenaltyNotificationBatch(seqID: seqID, penalties: notifications)
        
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        
        do {
            let encoded = try penaltyNotificationHeader + e.encode(batch)
            assert(encoded.count <= 1200)
            
            let usedPath = try connection.send(data: encoded, wantUsedPath: true).0?.path
            
            print("Sent penalty via \(usedPath?.canonicalFingerprintShortWithTCInfo ?? "-")")
            
            let pun = OverlapPathProcessor()
            let full = connection.fullPathProcessor.joinFlat(with: pun)
            
//            if punishment > 0 {
                noNonCriticalPenaltiesUntil = Date().addingTimeInterval(criticalGracePeriod ?? noncriticalPenaltiesGracePeriodAfterPathSwitch)
//            }
            
            // Send twice for reliability. The second time we send on a path that ideally shares as few links as possible with the first path
            func sendAgain(penalizing: SCIONPath?, remaining: Int) {
                guard remaining > 0 else { return }
                
                CallQualityMonitor.penaltyQueue.asyncAfter(deadline: .now() + 0.05) {
                    do {
                        var pathToUse: SCIONPath?
                        
                        if let used = penalizing {
                            pun.referencePaths += [(used, 1)]

                            pathToUse = full.process(connection.rootPaths, context: 0).first
                            
                            if pathToUse != nil {
                                sendAgain(penalizing: pathToUse, remaining: remaining - 1)
                            }
                        }
                        else {
                            pathToUse = nil
                        }
                        
                        print("Sent penalty via \(pathToUse?.canonicalFingerprintShortWithTCInfo ?? "-")")
                        
                        try connection.send(data: encoded, path: pathToUse)
                    }
                    catch {
                        print("Failed to send penalty info: \(error)")
                    }
                }
            }
            
            sendAgain(penalizing: usedPath, remaining: repeatPenaltyCount + 2)
        }
        catch {
            print("Failed to send penalty info: \(error)")
        }
    }
    
    func consume(next report: StatisticsReport) {
        fatalError("Must be overridden")
    }
}

struct FreezePair {
    let start: Date
    let duration: TimeInterval
}

struct TestSnapshot {
    let timestamps: [Date]
    let resolutionTimeline: [Int]
    let FPSTimeline: [Int]
    let freezes: [FreezePair]
    let penaltyTimes: [Date]
}

extension FreezePair: Codable {}
extension TestSnapshot: Codable {}

final class VideoCallQualityMonitor: CallQualityMonitor {
    private let freezeCountMetric = TimedMetric<Int>()
    private let freezeDurationMetric = TimedMetric<Double>()
    
    // Used to keep track of the duration of received frames, and in turn to recognize freezes as they happen. Freeze metrics are only updated after a freeze has completed.
    private let receivedPacketsMetric = TimedMetric<Int>()
    
    private let resolutionMetric = TimedMetric<Int>()
    private let fpsMetric = TimedMetric<Int>()
    private var ignoreStallsUntil = Date.distantPast
    
    override init(channelType: ChannelType, connections: [AnyPublisher<SCIONUDPConnection, Never>], noncriticalPenaltiesGracePeriodAfterPathSwitch: TimeInterval) {
        assert(channelType == .video)
        super.init(channelType: channelType, connections: connections, noncriticalPenaltiesGracePeriodAfterPathSwitch: noncriticalPenaltiesGracePeriodAfterPathSwitch)
        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "relay-stall"), object: nil, queue: .main) { [weak self] notification in
            if let ignoreStallsUntil = self?.ignoreStallsUntil, (notification.userInfo?["type"] as? ChannelType) == .video, Date() > ignoreStallsUntil {
                print("\n\nAPPLYING STALL PENATLY!!!\n\tTO: VIDEO\n\n")
                self?.apply(penalties: [Penalty(value: 0.5, critical: true, description: "Stall")])
                self?.ignoreStallsUntil = Date().addingTimeInterval(3)
            }
        }
    }
    
    override func consume(next _report: StatisticsReport) {
        CallQualityMonitor.penaltyQueue.async { [self] in
            if disableCallQualityMonitoring { return }
            
            let report = _report.video
            
            freezeCountMetric.add(entry: report.receiverTrack.freezeCount)
            freezeDurationMetric.add(entry: report.receiverTrack.totalFreezesDuration)
            
            assert(report.inboundRTP.frameHeight == report.receiverTrack.frameHeight)
            
            resolutionMetric.add(entry: report.inboundRTP.frameHeight ?? 0)
            fpsMetric.add(entry: report.inboundRTP.framesPerSecond ?? 0)
            
            receivedPacketsMetric.add(entry: report.transport.packetsReceived)
            
            let currentFreezeDuration = receivedPacketsMetric.duration { report.transport.packetsReceived - $0 <= 0 }
            if currentFreezeDuration > 0.5 {
                print("Ongoing video freeze \(currentFreezeDuration)")
            }
            
            var penalties = [Penalty]()

            if freezeCountMetric.difference(over: 5, operator: { $0 >= 5 }, "Matched freeze count 5") ||
                freezeCountMetric.difference(over: 10, operator: { $0 >= 8 }, "Matched freeze count 10") ||
                freezeCountMetric.difference(over: 30, operator: { $0 >= 10 }, "Matched freeze count 30") {
                penalties.append(Penalty(value: 0.4, critical: true, description: "Freezes"))
            }
            
            if freezeDurationMetric.difference(over: 5, operator: { $0 >= 2 }, "Matched freeze duration 5") ||
                freezeDurationMetric.difference(over: 10, operator: { $0 >= 3 }, "Matched freeze duration 10") ||
                freezeDurationMetric.difference(over: 30, operator: { $0 >= 7 }, "Matched freeze duration 30") {
                penalties.append(Penalty(value: 0.4, critical: false, description: "Freezes"))
            }
            
            // Were we frozen for the last 2 seconds
            if currentFreezeDuration >= 2 {
                penalties.append(Penalty(value: 0.4, critical: true, description: "Ongoing Freeze"))
            }
            
            // Ideally there should be a check for resolution here as well. Unfortunately WebRTC does whatever it wants, and it isn't very sure of what it even wants. When getting onto a path with horrible bandwidth, WebRTC will usually respond by reducing the resolution bit by bit. Even after the SCION path has long changed onto a better path, WebRTC will stick to its belief that the bandwidth just sucks and will eventually get to 180p resolution AND IT JUST STAYS THERE. So the resolution metric is utterly useless when it comes to low resolution. WebRTC is unaware of paths and making it aware of paths would certainly help – the bandwidth estimator specifically. Also, the bandwidth estimator simply sucks ass.
            if fpsMetric.average(over: 30, relative: false, operator: { $0 < 13 })
            {
                penalties.append(Penalty(value: 0.2, critical: false, description: "Low FPS"))
            }
            
            if fpsMetric.average(over: 4, relative: false, operator: { $0 <= 5 }) && (fpsMetric.entries.last?.1 ?? 5) <= 5
            {
                penalties.append(Penalty(value: 0.3, critical: false, description: "Very Low FPS"))
            }
            
            // Allow giving small rewards to good paths
            if penalties.isEmpty {
                if freezeCountMetric.difference(over: 45, operator: { $0 < 1 }) &&
                    freezeCountMetric.difference(over: 45, operator: { $0 < 2 }) &&
                    currentFreezeDuration == 0 &&
                    resolutionMetric.average(over: 60, relative: false, operator: { $0 > 450 }) &&
                    fpsMetric.average(over: 30, relative: false, operator: { $0 > 19 })
                {
                    penalties.append(Penalty(value: -0.2, critical: false, description: "Good Resolution + FPS + No Freeze"))
                }
                
                if (resolutionMetric.average(over: 60, relative: false, operator: { $0 > 700 }) &&
                        (resolutionMetric.entries.last?.1 ?? 0) > 700) ||
                    fpsMetric.average(over: 30, relative: false, operator: { $0 > 24 })
                {
                    penalties.append(Penalty(value: -0.1, critical: false, description: "Very Good Resolution + FPS"))
                }
            }
            
            freezeCountMetric.purge(anythingOlderThan: 60)
            freezeDurationMetric.purge(anythingOlderThan: 60)
            receivedPacketsMetric.purge(anythingOlderThan: 5)
            resolutionMetric.purge(anythingOlderThan: 60)
            fpsMetric.purge(anythingOlderThan: 60)
            
            apply(penalties: penalties)
            
            let hasPenalty = penalties.contains(where: { $0.value > 0 })
            
            if testCase.isVideoCallTest && !isCloud() {
                testMonitor(report, hasPenalty)
            }
        }
    }
    
    // For tests only:
    private var testStarted = false
    private var subsequent720p = 0
    
    private var testTimestamps = [Date]()
    private var testResolutionTimeline: [Int] = []
    private var testFPSTimeline: [Int] = []
    private var testFreezes: [FreezePair] = []
    private var testPenaltyTimes: [Date] = []
    
    private var testTicks = 0
    
    var testTick: (Int, TestSnapshot) -> Void = {_, _ in}

    private func testMonitor(_ report: StatisticsReportVideo, _ hasPenalty: Bool) {
        guard testCase.isVideoCallTest else {
            fatalError("Only for test")
        }
        if report.receiverTrack.frameHeight == 720 {
            subsequent720p += 1
        }
        else {
            subsequent720p = 0
        }
        
        if testStarted {
            testTicks += 1
            
            let now = Date()
            testTimestamps.append(now)
            testResolutionTimeline.append(report.receiverTrack.frameHeight ?? 0)
            testFPSTimeline.append(report.inboundRTP.framesPerSecond ?? 0)
            
            if hasPenalty {
                testPenaltyTimes.append(now)
            }
            
            // Get the amount of freezes reported since the last tick
            let freezeDuration = freezeDurationMetric.getDifference(overCount: 2)
            if freezeDuration > 0 {
                let freezeStart = now.addingTimeInterval(-freezeDuration)
                testFreezes.append(FreezePair(start: freezeStart, duration: freezeDuration))
            }
            
            let snapshot = TestSnapshot(timestamps: testTimestamps, resolutionTimeline: testResolutionTimeline, FPSTimeline: testFPSTimeline, freezes: testFreezes, penaltyTimes: testPenaltyTimes)
            
            testTick(testTicks, snapshot)
        }
        else if subsequent720p > 5 && !testStarted {
            testStarted = true
        }
    }
}

final class AudioCallQualityMonitor: CallQualityMonitor {
    private let freezeCountMetric = TimedMetric<Int>()
    private let freezeDurationMetric = TimedMetric<Double>()
    
    private let receivedPacketsMetric = TimedMetric<Int>()
    var referenceVideoMonitor: VideoCallQualityMonitor?
    
    private var ignoreStallsUntil = Date.distantPast
    
    override init(channelType: ChannelType, connections: [AnyPublisher<SCIONUDPConnection, Never>], noncriticalPenaltiesGracePeriodAfterPathSwitch: TimeInterval) {
        assert(channelType == .audio)
        super.init(channelType: channelType, connections: connections, noncriticalPenaltiesGracePeriodAfterPathSwitch: noncriticalPenaltiesGracePeriodAfterPathSwitch)
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "relay-stall"), object: nil, queue: .main) { [weak self] notification in
            if let ignoreStallsUntil = self?.ignoreStallsUntil, (notification.userInfo?["type"] as? ChannelType) == .audio, Date() > ignoreStallsUntil {
                print("\n\nAPPLYING STALL PENATLY!!!\n\tTO: AUDIO\n\n")
                self?.apply(penalties: [Penalty(value: 0.5, critical: true, description: "Stall")])
                self?.ignoreStallsUntil = Date().addingTimeInterval(3)
            }
        }
    }
    
    override func consume(next _report: StatisticsReport) {
        CallQualityMonitor.penaltyQueue.async { [self] in
            if disableCallQualityMonitoring { return }
            
            let report = _report.audio
            
            freezeCountMetric.add(entry: report.receiverTrack.interruptionCount)
            freezeDurationMetric.add(entry: report.receiverTrack.totalInterruptionDuration)
            
            receivedPacketsMetric.add(entry: report.transport.packetsReceived)

            let currentFreezeDuration = receivedPacketsMetric.duration { report.transport.packetsReceived - $0 <= 0 }
            if currentFreezeDuration > 0.5 {
                print("Ongoing audio freeze \(currentFreezeDuration)")
            }
            
            var penalties = [Penalty]()

            if freezeCountMetric.difference(over: 5, operator: { $0 >= 5 }, "Matched freeze count 5") ||
                freezeCountMetric.difference(over: 10, operator: { $0 >= 8 }, "Matched freeze count 10") ||
                freezeCountMetric.difference(over: 30, operator: { $0 >= 10 }, "Matched freeze count 30") {
                penalties.append(Penalty(value: 0.4, critical: true, description: "Freezes"))
            }
            
            if freezeDurationMetric.difference(over: 5, operator: { $0 >= 2 }, "Matched freeze duration 5") ||
                freezeDurationMetric.difference(over: 10, operator: { $0 >= 3 }, "Matched freeze duration 10") ||
                freezeDurationMetric.difference(over: 30, operator: { $0 >= 7 }, "Matched freeze duration 30") {
                penalties.append(Penalty(value: 0.4, critical: false, description: "Freezes"))
            }
            // Were we frozen for the last 2 seconds
            if currentFreezeDuration >= 2 {
                penalties.append(Penalty(value: 0.4, critical: true, description: "Ongoing Freeze"))
            }
            
            // Allow giving small rewards to good paths
            if penalties.isEmpty &&
                freezeDurationMetric.difference(over: 45, operator: { $0 < 0.5 }) &&
                freezeCountMetric.difference(over: 45, operator: { $0 < 2 }) &&
                currentFreezeDuration == 0 {
                penalties.append(Penalty(value: -0.1, critical: false, description: "Low Freezes"))
            }
            
            freezeCountMetric.purge(anythingOlderThan: 60)
            freezeDurationMetric.purge(anythingOlderThan: 60)
            receivedPacketsMetric.purge(anythingOlderThan: 5)
            
            // If video and audio share the same connections then video has a much larger impact. If video gets penalized, reset the audio stats to give audio a chance to stay on the current paths and see if audio works better without the video
            if currentPaths == referenceVideoMonitor?.lastPenalized {
                resetStats()
                penalties.removeAll()
            }
            
            apply(penalties: penalties)
        }
    }
}
