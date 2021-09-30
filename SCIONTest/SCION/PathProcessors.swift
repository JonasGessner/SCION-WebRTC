//
//  PathProcessors.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 10.05.21.
//

import Foundation
import SCIONDarwin
import Combine
import CombineExt

extension FixedWidthInteger {
    func encodeBinary() -> Data {
        let byteSize = type(of: self).bitWidth / 8
        
        let littleEndian = self.littleEndian
        
        return withUnsafePointer(to: littleEndian) { pointer -> Data in
            Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: byteSize, deallocator: .none)
        }
    }
}

extension FixedWidthInteger {
    init(decoding data: Data) throws {
        var val = Self()
        let byteSize = type(of: val).bitWidth / 8
        
        withUnsafeMutablePointer(to: &val) { pointer -> Void in
            pointer.withMemoryRebound(to: UInt8.self, capacity: byteSize) { bytePointer -> Void in
                data.copyBytes(to: bytePointer, count: byteSize)
            }
        }
        
        self = Self(littleEndian: val)
    }
}

protocol PathProcessor {
    func process(_ paths: [SCIONPath], context: Int64) -> [SCIONPath]
    
    var id: String { get }
}

protocol PredicatePathProcesor: PathProcessor {
    // These might as well be functions not closures as properties
    /// <
    var sortingPredicate: (SCIONPath, SCIONPath) -> Bool { get }
    /// isIncluded
    var filterPredicate: (SCIONPath) -> Bool { get }
}

struct NoHellPathProcessor: PathProcessor {
    func process(_ paths: [SCIONPath], context: Int64) -> [SCIONPath] {
        return paths.map({ ($0, $0.metadata?.linkMetadata.compactMap({ $0.hellDescription }).count ?? 0) }).sorted(by: { $0.1 < $1.1 }).map({ $0.0 })
    }
    
    let id = "No Hell"
}

fileprivate final class HellRNG: RandomNumberGenerator {
    private static let staticNumbers: [UInt64] = [69, 421, 0xdeadbeef, 0xba55, 0xb16b00b5, 0xbada55, 12089, 1081, 3450, 5, 239, 150, 594, 12059781, 1150912, 82367262, 2259, 24597834, 2345967823, 6767575757, 696969696, 42069]
    private var i = 0
    private let numbers: [UInt64]
    
    init(seed: UInt64) {
        var i: UInt64 = 0
        numbers = HellRNG.staticNumbers.reduce(into: [], { ac, next in
            ac += CollectionOfOne(next &* seed &- (i ^ seed))
            i += 1
        })
    }
    
    func next() -> UInt64 {
        defer { i += 1; i %= numbers.count }
        return numbers[i]
    }
}

// Only needed for my very specific test setup. This filters paths and makes sure both sides of a connection see the same paths. THIS HAS NO USE ANYWHERE EXCEPT IN MY TEST SETUP
struct HellPreprocessor: ActivePathProcessor {
    var orderingChanged = PassthroughSubject<Int64, Never>()
    
    // Ignores the paths of the other peer, does not try to produce paths that are known to both peers. Simply matches up interface numbers for traffic control
    var onlyMatchInterfaces = testCase == .addedLatency || testCase == .addedLoss || testCase == .exactLatencyPlot || testCase == .latencyCompare
    
    func connect(to connection: SCIONUDPConnection) {
    }
    
    func handleReceive(of message: SCIONMessage, on connection: SCIONUDPConnection) -> Bool {
        return true
    }
    
     let id = "Hell Preprocessor"
    
    static var instanceID = UUID()
    // I have no idea why (probably bceuase "f you"), but ETH and AWS find different paths partially. This completely messes up the hell preprocessor because both sides should obviously use the same paths (== same interface numbers).
    // So here the paths found by each side are hardcoded so that the intersection can be used
    static var pathsOther = [String]() {
        didSet {
            newRemotePathsPublisher.send()
        }
    }
    
    // Used for ghetto path exchange
    static var newLocalPathsPublisher = PassthroughSubject<(UUID, [SCIONPath]), Never>()
    static var newRemotePathsPublisher = PassthroughSubject<Void, Never>()
    
    private let sub: AnyCancellable
    init() {
        sub = HellPreprocessor.newRemotePathsPublisher
            .map({ 0 })
            .subscribe(orderingChanged)
        
    }
    // For some reason Swifts `.shuffled(with: )` does NOTHING when passing in a custom RNG like SeededGenerator.... So here we are writing a custom, really bad, shuffle function
    private func hellShuffle(_ paths: [SCIONPath]) -> [SCIONPath] {
        var mut = paths
        let rng = HellRNG(seed: 0xdd05ed)
        
        for i in 0..<UInt64(paths.count) * 69 {
            let a = (((((rng.next() &* (i &+ 1)) % UInt64(mut.count)) ^ i) &+ i) ^ rng.next()) % UInt64(mut.count)
            let b = (((((rng.next() &* (i &+ 1)) % UInt64(mut.count)) ^ i) &+ i) ^ rng.next()) % UInt64(mut.count)
            
            mut.swapAt(Int(a), Int(b))
        }
        
        return mut
    }
    
    func process(_ paths: [SCIONPath], context: Int64) -> [SCIONPath] {
        if paths.isEmpty {
            print("WTF NO PATHS?")
            return paths
        }
        if paths.contains(where: { $0.metadata == nil }) {
            print("WTF NO METADATA?")
            return paths
        }
        
        let hell = defaultAS == .hell
        
        // Have to handle the cloud machine differently. On the cloud machine we get paths FROM the hell AS. On ETH we get paths TO the hell AS. The result of this preprocessor should be the same regardsless, and to do this we have to handle the two cases separately.
        
        let firstAS = !hell ? paths[0].metadata!.linkMetadata.last!.toIA : paths[0].metadata!.linkMetadata.first!.fromIA
        
        let lastAS = hell ? paths[0].metadata!.linkMetadata.last!.toIA : paths[0].metadata!.linkMetadata.first!.fromIA
        
        if firstAS == "16-ffaa:1:ede" && lastAS == "16-ffaa:1:f04" {
            return paths
        }
        else if firstAS == "16-ffaa:1:f04" {
            // Super hacky implementation for syncing available paths across clients. We want both sides of the connection to USE THE SAME PATHS. BUT THE PATHS KEEP CHANGING In SCIONLAB!! So do some sketchy exchange of paths
            HellPreprocessor.newLocalPathsPublisher.send((HellPreprocessor.instanceID, paths))

            let usablePaths = Set(paths.map({ $0.canonicalFingerprintShort })).intersection(HellPreprocessor.pathsOther)
            
            let blacklistFiltered = (onlyMatchInterfaces || HellPreprocessor.pathsOther.isEmpty) ? paths : paths.filter({ usablePaths.contains($0.canonicalFingerprintShort) })

            // For tests only
            if blacklistFiltered.count == 1 {
                return blacklistFiltered
            }
            
            let sourceIfas = Set(blacklistFiltered.map({ !hell ? $0.metadata!.linkMetadata.last!.toInterfaceID : $0.metadata!.linkMetadata.first!.fromInterfaceID }))

            assert(!sourceIfas.isEmpty)

            // Filter out nonsensical paths. Th iface id of the first egress must match the iface id of the second egress (when looking from the direction of the hell AS).
            let prefiltered = blacklistFiltered
                .filter({ !hell ?
                            $0.metadata!.linkMetadata.last!.toInterfaceID == $0.metadata!.linkMetadata[$0.metadata!.linkMetadata.count - 3].toInterfaceID :
                            $0.metadata!.linkMetadata[0].fromInterfaceID == $0.metadata!.linkMetadata[2].fromInterfaceID })

            let pathsPerSourceIfa = (prefiltered.count / sourceIfas.count) / sourceIfas.count

            // Categorize paths by hell interface [hellifa: [paths going over hellifa]]. The paths in each of these categories are also sorted, invariant to the hellifa.
            let categorized = Dictionary(uniqueKeysWithValues: sourceIfas.map({ ifa -> (UInt64, [SCIONPath]) in
                if !hell {
                    let sorted = prefiltered.filter({ $0.metadata!.linkMetadata.last!.toInterfaceID == ifa })
                        .sorted(by: { $0.fingerprint < $1.fingerprint })

                    let shuffled = hellShuffle(sorted)

                    assert(sorted != shuffled)
                    return (ifa, shuffled)
                }
                else {
                    let sorted = prefiltered.filter({ $0.metadata!.linkMetadata.first!.fromInterfaceID == ifa })
                        .sorted(by: { $0.reverseFingerprint < $1.reverseFingerprint })

                    let shuffled = hellShuffle(sorted)

                    assert(sorted != shuffled)
                    return (ifa, shuffled)
                }
            }))

            // All categories should have the same number of paths
            assert(Set(categorized.values.map({ $0.count })).count == 1)

            // This uses the first `pathsPerSourceIfa` paths via the first hell interface, the second `pathsPerSourceIfa` via the second interface, etc. We end up with the same amount of paths as in
            let interleaved = categorized
                .sorted(by: { $0.key < $1.key })
                .map({ $0.value })
                .enumerated()
                .flatMap({ index, relevantPaths -> [SCIONPath] in
                    if index == sourceIfas.count - 1 {
                        return Array(relevantPaths[(index * pathsPerSourceIfa)...])
                    }
                    else {
                        return Array(relevantPaths[(index * pathsPerSourceIfa)..<((index + 1) * pathsPerSourceIfa)])
                    }
                })

            let final = (hell ? interleaved.sorted(by: { $0.fingerprint < $1.fingerprint }) : interleaved.sorted(by: { $0.reverseFingerprint < $1.reverseFingerprint }))
            
//            // Just do a hardcoded check here to be sure
//            guard final.map({ $0.canonicalFingerprintShort }).joined(separator: ",") == "3944e,08c27,492eb,1ddeb,3cf36,6c11d,3fd82,13b0b,d025f,47081,3f894,4a995,ecc66,f5fb6,643ab,b759a,fe3a4,3c6f7,cb9c9,3ddc1,6a6c6,6a9ef,f085f,6ce09" else {
//                fatalError("Invalid hell preprocessed paths")
//            }

            return final
        }
        // The non hell ETH AS. First take the first interface
        else if firstAS == "16-ffaa:1:ede" {
            return paths.filter({
                !hell ? $0.metadata!.linkMetadata.last!.toInterfaceID == 1 :
                    $0.metadata!.linkMetadata.first!.fromInterfaceID == 1
            })
        }
        // Nothing to be done when somewhere else
        else {
            return paths
        }
    }
}

/// An active path processor is aware of the connection(s) it is used on and can actively participate in traffic sending and receiving. It can dynamically change its path sorting predicates and uses the `predicatesChanged` publisher to inform connections that they need to re-evaluate their paths according to the new predicates.
protocol ActivePathProcessor: PathProcessor {
    // Passed pointer contains a context that is carried all the way through the update pipeline
    var orderingChanged: PassthroughSubject<Int64, Never> { get } // Could use observable object, but that would add stupid generic constraints and force the use of generics everywhere where this type is used.
    func connect(to connection: SCIONUDPConnection)
    /// Return false to drop the packet
    func handleReceive(of message: SCIONMessage, on connection: SCIONUDPConnection) -> Bool
}

final class LatencyProbingPathProcessor: ActivePathProcessor {
    private let probeBurstSize = 15
    private let reProbeInterval = 1//s
    private let probeTimeoutInterval = 1000//ms
    private let interProbeInterval = 20//ms
    private var maxMeasurementsToKeep: Int { return 2 * probeBurstSize }
   
    static var latencyProbingPaused = pauseLatencyProbingByDefault
    
    struct ProbeResult {
        fileprivate var measurements = [TimeInterval]()
        
        func calculateScore(for measurements: [TimeInterval]) -> Int? {
            let validMeasurements = measurements.filter({ $0 != .greatestFiniteMagnitude })
            if validMeasurements.isEmpty {
                return nil
            }
            let numberOfLosses = measurements.count - validMeasurements.count
            let sum = validMeasurements.reduce(0, +)
            
            let howNiceToRead = round(
                (Double(measurements.count + numberOfLosses * numberOfLosses) / Double(measurements.count)) *
                (Double(sum)/Double(max(validMeasurements.count, 1))) *
                1000)
            
            return Int(howNiceToRead)
        }
        
        mutating func updateOverallScore() {
            let validMeasurements = measurements.filter({ $0 != .greatestFiniteMagnitude })
            let numberOfLosses = measurements.count - validMeasurements.count
            // If more than 1/2 of the measurements were losses we declare the path to have maximum latency
            if Double(numberOfLosses)/Double(measurements.count) >= 0.5 {
                overallScore = nil
            }
            else {
                let sum = validMeasurements.reduce(0, +)
                // We penalize the divisor by the number of losses, resulting in a greater overall score when probes were lost
                let total = max(validMeasurements.count - numberOfLosses, 1)
                
                overallScore = Int(round((Double(sum)/Double(total)) * 1000))
            }
        }
        
        private(set) var overallScore: Int?
    }
    
    let orderingChanged = PassthroughSubject<Int64, Never>()
    private let queue = DispatchQueue(label: "latency probing", qos: .userInitiated)
    
    deinit {
        orderingChanged.send(completion: .finished)
    }
    
    private(set) var sortingPredicate: (SCIONPath, SCIONPath) -> Bool = {_,_ in true}
    let filterPredicate: (SCIONPath) -> Bool
    
    let id = "Latency Probing"
    
    private var firstProbe = true
    
    private var currentId: UInt64 = 0
    private var probeTable = [UInt64: (SCIONPath, Date)]()
    
    private(set) var latencyTable = [SCIONPath: ProbeResult]()
    
    private var timeouts = 0
    
    private var pendingProbes = 0 {
        didSet {
//             print("\(pendingBursts), \(pendingProbes)")
            if pendingBursts == 0 && pendingProbes == 0 && probing {
                probing = false
                queue.async {
                    self.probingCompleted()
                }
            }
        }
    }
    
    private var pendingBursts = 0
    private var probing = false // Is a probe currently running?
    private var wantsProbeAgainImmediately = false // If a probe is already running and this is true then after the probe completes a new one will immediately start
    private var receivedProbeResponses = 0
    
    private var scheduledReProbe: DispatchWorkItem?
    
    // MARK: - For tests only
    func mostRecentRunMeasurements(for path: SCIONPath) -> [TimeInterval] {
        lock.lock()
        defer {
            lock.unlock()
        }
        let res = latencyTable[path]!
        
        return res.measurements.suffix(probeBurstSize)
    }
    
    func mostRecentRunScore(for path: SCIONPath) -> TimeInterval? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let res = latencyTable[path]!
        
        return res.calculateScore(for: res.measurements.suffix(probeBurstSize)).map({ TimeInterval($0) / 1000.0 })
    }
    
    // Only probe paths contained in this mask. Probe all if mask is empty
    var pathMask = Set<SCIONPath>()
    
    let completionPublisher = PassthroughSubject<Void, Never>()
    // MARK: -
    
    func probingCompleted() {
        dispatchPrecondition(condition: .onQueue(queue))
        
        lock.lock()
        latencyTable = latencyTable.mapValues({ var mut = $0; mut.updateOverallScore(); return mut })
        lock.unlock()
        
        let totalProbes = probeBurstSize * (self.pathMask.isEmpty ? self.paths : self.paths.filter({ self.pathMask.contains($0) })).count
        
        probing = false
        firstProbe = false
        NSLog("Probing complete. Timeout rate \(Double(timeouts)/Double(totalProbes))")
        orderingChanged.send(0)
        scheduledReProbe?.cancel()
        scheduleNextProbe()
        
        completionPublisher.send()
    }
    
    private func scheduleNextProbe() {
        if connection?.closed == true {
            print("Connection closed. Shutting down latency prober")
            return
        }
        
        let scheduleItem = DispatchWorkItem(block: { [weak self] in
            self?.runProbe()
        })
        scheduledReProbe = scheduleItem
        
        queue.asyncAfter(deadline: .now() + .seconds(reProbeInterval), execute: scheduleItem)
        
        if wantsProbeAgainImmediately {
            print("Executing deferred probing now")
            wantsProbeAgainImmediately = false
            runProbe()
        }
    }
    
    // Don't want reference cycle — use weak here
    private weak var connection: SCIONUDPConnection? {
        didSet {
            runProbe()
        }
    }
    
    private var paths = [SCIONPath]() {
        didSet {
            if paths != oldValue {
                runProbe()
            }
        }
    }
    
    private let lock = NSLock()
    private let probeTableLock = NSLock()
    
    func score(for path: SCIONPath) -> TimeInterval {
        lock.lock()
        defer {
            lock.unlock()
        }
        return asyncScore(for: path)
    }
    
    private func asyncScore(for path: SCIONPath) -> TimeInterval {
        return latencyTable[path]?.overallScore.map { TimeInterval($0) / 1000 } ?? TimeInterval.greatestFiniteMagnitude
    }
    
    init() {
        filterPredicate = {_ in true}
        sortingPredicate = { [weak self] lhs, rhs in
            guard let self = self else { return false }
            return self.asyncScore(for: lhs) < self.asyncScore(for: rhs) || (self.asyncScore(for: lhs) == self.asyncScore(for: rhs) && lhs.hops < rhs.hops) || (self.asyncScore(for: lhs) == self.asyncScore(for: rhs) && lhs.hops == rhs.hops && lhs.canonicalFingerprintShort < rhs.canonicalFingerprintShort)
        }
    }
    
    func process(_ paths: [SCIONPath], context: Int64) -> [SCIONPath] {
        // Apply fixed ordering to keep the conditions of operations that are performed sequentially on the paths array the same
        self.paths = Array(paths.sorted(by: { $0.canonicalFingerprint < $1.canonicalFingerprint }))
        
        lock.lock()
        defer { lock.unlock() }

        return paths
            .filter(filterPredicate)
            .sorted(by: sortingPredicate)
                        
    }
    
    private func gotProbeResponse(_ id: UInt64, via replyPath: SCIONPathSource?) {
        dispatchPrecondition(condition: .notOnQueue(queue))
        
        probeTableLock.lock()
        guard let (path, start) = probeTable.removeValue(forKey: id) else {
            probeTableLock.unlock()
            print("Got probe reply for \(id) but was not expecting one!")
            return
        }
        probeTableLock.unlock()
        
        assert(path.fingerprint == replyPath?.fingerprint)
        
        let diff = Date().timeIntervalSince(start)
        registerMeasurement(diff, for: path)
    }
    
    private func registerMeasurement(_ diff: TimeInterval, for path: SCIONPath) {
        lock.lock()
        defer {
            lock.unlock()
            if firstProbe && (receivedProbeResponses % 20) == 0 {
                DispatchQueue.global(qos: .default).async {
                    self.orderingChanged.send(0)
                }
            }
        }
        var result = self.latencyTable[path, default: ProbeResult()]
        var measurements = result.measurements
        measurements.append(diff)
        if measurements.count > maxMeasurementsToKeep {
            measurements.removeFirst()
        }
        
        result.measurements = measurements
        
        if firstProbe {
            result.updateOverallScore()
        }
        
        latencyTable[path] = result
        
        receivedProbeResponses += 1
        pendingProbes -= 1
    }
    
    func connect(to connection: SCIONUDPConnection) {
        guard connection.wantsToBeUsedForLatencyProbing else { return }
        
        if let existingCon = self.connection {
            // TODO: Should not only compare ASes but also IP addresses. Not ports though
            if existingCon.localAddress.isInForeignAS(to: connection.localAddress) || existingCon.remoteAddress.isInForeignAS(to: connection.remoteAddress) {
                fatalError() // Can't connect to path processor because it is already configured for a different e2e path
            }
        }
        else {
            self.connection = connection
        }
    }
    
    func handleReceive(of message: SCIONMessage, on connection: SCIONUDPConnection) -> Bool {
        guard connection == self.connection else { return true }
        
        let data = message.contents
        
        if data.starts(with: probeResponse) {
            do {
//                print("Got probe response")
                let id = try UInt64(decoding: data[probeResponse.count...])
                self.gotProbeResponse(id, via: message.replyPath)
            }
            catch {
                print("Failed to decode probe response: \(error)")
            }
            return false
        }
        
        return true
    }
    
    private func sendProbe(via path: SCIONPath, on connection: SCIONUDPConnection) throws -> UInt64 {
        currentId += 1
        let encodedID = currentId.encodeBinary()
        
        _ = try connection.send(data: probeRequest + encodedID, path: path)
        
        return currentId
    }
    
    private func runProbe() {
        guard let connection = self.connection else { return }
        
        if connection.closed {
            print("Connection closed. Shutting down latency prober")
            return
        }
        
        guard !LatencyProbingPathProcessor.latencyProbingPaused else {
//            print("Latency probing is paused")
            scheduleNextProbe()
            return
        }
        
        queue.async {
            self.lock.lock()
            guard !self.probing else {
                self.lock.unlock()
                print("Tried running probe while another one was in progress. Deferring")
                self.wantsProbeAgainImmediately = true
                return
            }
            let paths = self.pathMask.isEmpty ? self.paths : self.paths.filter({ self.pathMask.contains($0) })
            guard !paths.isEmpty else {
                self.lock.unlock()
                print("No paths to probe")
                return
            }
            
            self.probing = true
            self.lock.unlock()
            
            NSLog("Starting probing")
            self.timeouts = 0
            self.pendingBursts += self.probeBurstSize
            
            var currentBurst = 0
            var currentPath = 0
            self.receivedProbeResponses = 0
            
//            var last = CFAbsoluteTimeGetCurrent()
            func next() {
//                let diff = CFAbsoluteTimeGetCurrent() - last
//                if diff > 0.005 {
//                    print("Dispatch async took long \(diff)")
//                }
                do {
                    let date = Date()
//                    let start = CFAbsoluteTimeGetCurrent()
                    let path = paths[currentPath]
                    let sentID = try self.sendProbe(via: path, on: connection)
//                    if CFAbsoluteTimeGetCurrent() - start > 0.01 {
//                        print("Slow send!!!! \(CFAbsoluteTimeGetCurrent() - start)")
//                    }
                    self.probeTableLock.lock()
                    self.probeTable[sentID] = (path, date)
                    self.probeTableLock.unlock()
                    self.pendingProbes += 1
                }
                catch {
                    if connection.closed {
                        print("Connection closed. Shutting down latency prober")
                        return
                    }
                    print("Failed to probe RTT \(error)")
                }
                
                currentPath += 1
                currentPath %= paths.count
                if currentPath == 0 {
                    currentBurst += 1
                    if currentBurst == self.probeBurstSize {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(self.probeTimeoutInterval)) {
                            self.probeTableLock.lock()
                            for (id, (path, _)) in self.probeTable {
                                // Timeout reached bruv
                                self.timeouts += 1
                                self.probeTable.removeValue(forKey: id)
                                self.registerMeasurement(.greatestFiniteMagnitude, for: path)
                            }
                            self.probeTableLock.unlock()
                            
                            if self.probing {
                                self.probingCompleted()
                            }
                        }
                        
                        NSLog("Probe sending complete")
                        return
                    }
                }
//                last = CFAbsoluteTimeGetCurrent()
                self.queue.asyncAfter(wallDeadline: .now() + .milliseconds(self.interProbeInterval)) {
                    next()
                }
            }
            
            next()
        }
    }
}

extension PredicatePathProcesor {
    func process(_ paths: [SCIONPath], context: Int64) -> [SCIONPath] {
        return paths.filter(filterPredicate).sorted(by: sortingPredicate)
    }
}

class SequentialPathProcessor: ActivePathProcessor {
    let processors: [PathProcessor]
    
    let orderingChanged = PassthroughSubject<Int64, Never>()
    
    deinit {
        orderingChanged.send(completion: .finished)
    }
    
    let activeProcessors: [ActivePathProcessor]
    
    let id: String
    
    fileprivate var subs = [AnyCancellable]()
    
    init(processors: [PathProcessor]) {
        self.processors = processors
        self.activeProcessors = processors.compactMap({ $0 as? ActivePathProcessor })
        id = processors.map({ $0.id }).joined(separator: ", ")
        subscribe()
    }
    
    fileprivate func subscribe() {
        subs = activeProcessors.map({
            $0.orderingChanged.subscribe(orderingChanged)
        })
    }
    
    func connect(to connection: SCIONUDPConnection) {
        activeProcessors.forEach({ $0.connect(to: connection) })
    }
    
    func handleReceive(of message: SCIONMessage, on connection: SCIONUDPConnection) -> Bool {
        return activeProcessors.reduce(true, { $0 && $1.handleReceive(of: message, on: connection) })
    }
    
    func process(_ paths: [SCIONPath], context: Int64) -> [SCIONPath] {
        return processors.reduce(paths, { $1.process($0, context: context) })
    }
    
    func byAdding(additional pathProcessors: [PathProcessor]) -> SequentialPathProcessor {
        return SequentialPathProcessor(processors: processors + pathProcessors)
    }
    
    func byCollectingPenalties() -> SequentialPathProcessor {
        enum Collect {
            case pun([PathPenalizer])
            case noPun(PathProcessor)
        }
        
        let collected = processors.reduce(into: [Collect]()) { ac, p in
            if let pun = p as? PathPenalizer {
                if case var .pun(collect) = ac.last {
                    collect.append(pun)
                    ac.removeLast()
                    ac.append(.pun(collect))
                }
                else {
                    ac.append(.pun([pun]))
                }
            }
            else {
                ac.append(.noPun(p))
            }
        }
        
        let mapped = collected.map({ c -> PathProcessor in
            switch c {
            case .noPun(let p):
                return p
            case .pun(let puns):
                return CollectedPathPunisher(puns)
            }
        })
        
        return SequentialPathProcessor(processors: mapped)
    }
}

/// This path processor is ALWAYS wrapped around
final class RootPathProcessor: SequentialPathProcessor {
    private var lastSelected: SCIONPath?
    private var pathWhenStartingFailover: SCIONPath?
    
    private(set) var rootPaths = [SCIONPath]()
    
    let failoverPublisher = PassthroughSubject<(old: SCIONPath, new: SCIONPath), Never>()

    deinit {
        subs.forEach({
            $0.cancel()
        })
        subs.removeAll()
        failoverPublisher.send(completion: .finished)
    }
    
    override func process(_ paths: [SCIONPath], context: Int64) -> [SCIONPath] {
        rootPaths = paths
        let processed = super.process(paths, context: context)
        let newLastSelected = processed.first
        if context == 1 {
            if lastSelected != newLastSelected,
               let old = lastSelected,
               let new = newLastSelected {
                print("Failover completed (1)")
                failoverPublisher.send((old, new))
            }
            else if pathWhenStartingFailover != newLastSelected,
                    let old = pathWhenStartingFailover,
                    let new = newLastSelected {
                print("Failover completed (2)")
                failoverPublisher.send((old, new))
            }
            else {
                print("Failover completed but nothing changed")
            }
        }
        lastSelected = newLastSelected
        return processed
    }
    
    override fileprivate func subscribe() {
        subs = activeProcessors.map({
            $0.orderingChanged
                .handleOutput({ [weak self] ctx in
                    if ctx == 1 {
                        self?.pathWhenStartingFailover = self?.lastSelected
                        print("Starting failover")
                    }
                })
                .subscribe(orderingChanged)
        })
    }
    
}

/**
 Path penalizer is a relative path processor that reorders the given paths by penalty weights assigned to each path.
 */
class PathPenalizer: ActivePathProcessor {
    var id: String = "Penalizer"
    
    let considerAsFailover: Bool
    
    let orderingChanged = PassthroughSubject<Int64, Never>()
    
    deinit {
        orderingChanged.send(completion: .finished)
    }
    
    private let lock = NSRecursiveLock()
    
    private var punishmentWeights = [SCIONPath: Double]()
    
    func mutating(by map: ([SCIONPath: Double]) -> [SCIONPath: Double], countsAsFailover: Bool) {
        lock.lock()
        defer {
            lock.unlock()
            orderingChanged.send(considerAsFailover && countsAsFailover ? 1 : 0)
        }
        punishmentWeights = map(punishmentWeights)
    }
    
    init(considerAsFailover: Bool) {
        self.considerAsFailover = considerAsFailover
    }
    
    func punishmentWeight(for path: SCIONPath) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return unlockedPunishmentWeight(for: path)
    }
    
    private func unlockedPunishmentWeight(for path: SCIONPath) -> Double {
        return punishmentWeights[path, default: 0]
    }
    
    func connect(to connection: SCIONUDPConnection) {
    }
    
    func handleReceive(of message: SCIONMessage, on connection: SCIONUDPConnection) -> Bool {
        return true
    }
    
    func process(_ paths: [SCIONPath], context: Int64) -> [SCIONPath] {
        return paths
            .enumerated()
            .map({ offset, element -> (SCIONPath, [Int]) in
                let weight = punishmentWeight(for: element)
                
                let penalty = Int(round(Double(paths.count) * weight))

                return (element, [offset + penalty, penalty.signum(), offset])
            })
            .sorted(by: { $0.1.lexicographicallyPrecedes($1.1) })
            .map({ $0.0 })
    }
}

/// Penalizes paths based on their overlap with given reference paths
final class OverlapPathProcessor: PathPenalizer {
    private let lock = NSLock()
    
    var referencePaths = [(SCIONPath, Double)]() {
        willSet {
            lock.lock()
        }
        didSet {
            if referencePaths.elementsEqual(oldValue, by: { $0.1 == $1.1 && $0.0 == $1.0 && !($0.0.metadata != nil && $1.0.metadata == nil) }) {
                lock.unlock()
                return
            }
            lock.unlock()
            orderingChanged.send(0)
        }
    }
    
    var sub: AnyCancellable?
    
    init() {
        super.init(considerAsFailover: false)
    }
    
    init(referenceConnection: SCIONUDPConnection, scale: Double = 1.0) {
        super.init(considerAsFailover: false)
        sub = referenceConnection.$effectivePath
            .map({ $0.map({ [($0, scale)] }) ?? [] })
            .assign(to: \.referencePaths, on: self, ownership: .weak)
    }
    
    override func punishmentWeight(for path: SCIONPath) -> Double {
        lock.lock()
        defer { lock.unlock() }
        
        guard let meta = path.metadata, !referencePaths.isEmpty else { return 0 }
        
        return Double(referencePaths.reduce(0, {
            $0 + ($1.0.metadata.map({ meta.linkOverlap(with: $0) }) ?? 0) * $1.1
        })) / Double(referencePaths.count)
    }
    
    override func process(_ paths: [SCIONPath], context: Int64) -> [SCIONPath] {
        return super.process(paths, context: context)
    }
}

/// Efficient wrapper for several chained path penalizers.
final class CollectedPathPunisher: PathPenalizer {
    private let puns: [PathPenalizer]
    
    init(_ puns: [PathPenalizer]) {
        self.puns = puns
        super.init(considerAsFailover: puns.contains(where: { $0.considerAsFailover }))
    }
    
    override func punishmentWeight(for path: SCIONPath) -> Double {
        return puns.reduce(0, { $0 + $1.punishmentWeight(for: path) })
    }
}

/// Sort paths by hop count
struct HopPathSorter: PredicatePathProcesor {
    var sortingPredicate: (SCIONPath, SCIONPath) -> Bool = { $0.hops < $1.hops }
    let filterPredicate: (SCIONPath) -> Bool = {_ in true}
    let id = "Hop Count"
} 

/// Sort paths by static latency information
struct LatencyPathSorter: PredicatePathProcesor {
    var sortingPredicate: (SCIONPath, SCIONPath) -> Bool = { $0.metadata?.pathLatency ?? 0 < $1.metadata?.pathLatency ?? 0 }
    let filterPredicate: (SCIONPath) -> Bool = {_ in true}
    let id = "Latency"
}

/// Special sorter that triggers specific behavior on a connection to use the last incoming path and send outgoing packets on the same path (mirrored). It doesn't do anything itself and is just recognized by connections to enable mirroring behavior in the connection itself.
struct MirrorPathSorter: PredicatePathProcesor {
    let sortingPredicate: (SCIONPath, SCIONPath) -> Bool = { $0.hops < $1.hops }
    let filterPredicate: (SCIONPath) -> Bool = {_ in fatalError("This should never be invoked. The mirror path processor cannot be used explicitly – it can only be set as the path processor of a connection, which contains dedicated logic for")}
    let id = "Mirror"
}
