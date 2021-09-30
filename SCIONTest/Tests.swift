//
//  Tests.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 27.08.21.
//

import Foundation
import Combine

struct ErrorString: LocalizedError {
    let string: String
    
    var errorDescription: String? {
        return string
    }
}

func shell(_ command: String) -> Result<Data, ErrorString> {
    let task = Process()
    let pipe = Pipe()
    
    task.standardOutput = pipe
    task.standardError = pipe
    task.arguments = ["-c", "-l", command]
    task.launchPath = "/bin/zsh"
    task.launch()
    task.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    
    if task.terminationStatus != 0 {
        return .failure(ErrorString(string: String(data: data, encoding: .utf8)!))
    }
    
    return .success(data)
}

func startTests() {
    LatencyProbingPathProcessor.latencyProbingPaused = false
    if isCloud() {
        startTestsCloud()
    }
    else {
        startTestsETH()
    }
}

extension Result {
    @discardableResult func forceSuccess() -> Success {
        switch self {
        case .failure(let error):
            fatalError("\(error)")
        case .success(let s):
            return s
        }
    }
}

struct LatencyProbeRun: Codable {
    let score: TimeInterval
    let measurements: [TimeInterval]
}

struct LatencyTestResult: Codable {
    let paths: [String]
    let pathFingerprints: [String]
    let results: [Int: [[LatencyProbeRun]]]
}

private func runLatencyTest(for conn: SCIONUDPConnection, prober p: LatencyProbingPathProcessor, pathSelector: @escaping ([SCIONPath]) -> [SCIONPath], actionPerStage: @escaping (Int) -> Bool) {
    if isCloud() {
        shell("ssh -t root@192.168.64.2 './tc.sh config 0 0'").forceSuccess()
    }
    else {
        shell("ssh -t administrator@207.254.31.242 \"ssh -t root@192.168.64.2 './tc.sh config 0 0'\"").forceSuccess()
    }
    
    let runsPerStage = 50
    
    conn.$paths
        .filter({ $0.count > 1 })
        .first()
        .autoDisposableSink(receiveValue:  { paths in
            print("Got paths. ")
            let paths = pathSelector(paths)
            
            p.pathMask = Set(paths)
            
            var currentStage = 0
            var currentStageRuns = -5 // Start at -10 to ignore the first 10 runs
            var runResults = [Int: [[LatencyProbeRun]]]()
            p.completionPublisher.autoDisposableSink(receiveValue:  { _ in
                if currentStageRuns >= 0 {
                    var runs: [LatencyProbeRun] = []
                    for path in paths {
                        guard let score = p.mostRecentRunScore(for: path) else {
                            print("Got a timeout. Skipping")
                            return
                        }
                        
                        let run = LatencyProbeRun(score: score, measurements: p.mostRecentRunMeasurements(for: path))
                        
                        runs.append(run)
                    }
                    
                    for (i, run) in runs.enumerated() {
                        var currentRunResults = runResults[currentStage, default: [[LatencyProbeRun]](repeating: [], count: paths.count)]
                        currentRunResults[i].append(run)
                        runResults[currentStage] = currentRunResults
                    }
                }
                
                currentStageRuns += 1
                if currentStageRuns == runsPerStage {
                    currentStageRuns = 0
                    currentStage += 1
                    if !actionPerStage(currentStage) {
                        let result = LatencyTestResult(paths: paths.map({ $0.description }), pathFingerprints: paths.map({ $0.canonicalFingerprintShort }), results: runResults)
                        let encoded = try! JSONEncoder().encode(result)
                        
                        try! encoded.write(to: URL(fileURLWithPath: "\(resultsBasePath)/result-\(testCase.rawValue)-\(Date().timeIntervalSince1970).json"))
                        
                        print(String(data: encoded, encoding: .utf8)!)
                        exit(0)
                    }
                }
            })
        })
}

private func runLatencyTestCloud(pathSelector: @escaping ([SCIONPath]) -> [SCIONPath], actionPerStage: @escaping (Int) -> Bool) {
    precondition(isCloud())
    
    let p = LatencyProbingPathProcessor()
    let listener = try! SCIONUDPListener(listeningOn: 1069, pathProcessor: SequentialPathProcessor(processors: [HellPreprocessor(), p]), receiveExtension: LatencyProbingReceiveExtension(), wantsToBeUsedForLatencyProbing: true)
    
    listener.accept().autoDisposableSink(receiveValue:  { conn in
        conn.listen().autoDisposableSink()
        print("Got conn. Starting test")
        runLatencyTest(for: conn, prober: p, pathSelector: pathSelector, actionPerStage: actionPerStage)
    })
}

private func runLatencyTestETH(pathSelector: @escaping ([SCIONPath]) -> [SCIONPath], actionPerStage: @escaping (Int) -> Bool) {
    precondition(!isCloud())
    
    let l = LatencyProbingPathProcessor()
    let conn = try! SCIONUDPConnection(clientConnectionTo: "16-ffaa:1:f04,192.168.64.1:1069", pathProcessor: SequentialPathProcessor(processors: [HellPreprocessor(), l]), receiveExtension: LatencyProbingReceiveExtension(), wantsToBeUsedForLatencyProbing: true)
    
    conn.listen().autoDisposableSink()
    
    runLatencyTest(for: conn, prober: l, pathSelector: pathSelector, actionPerStage: actionPerStage)
}

/// Record the latencies of multiple paths over time. To see if outliers/spikes in latency appear on all paths at the same time or not
private func multiplePathsLatencyTracing() {
    let tcGroup = 0
    // For this, turn down runsPerStage to 50
    runLatencyTestETH { paths in
        let wantedPaths = ["deb09", "47a96", "a3214", "3944e"]
        let filtered = paths.filter({ wantedPaths.contains($0.canonicalFingerprintShort) })
        
        return Array(filtered)
    } actionPerStage: { stage in
        let shellResult = shell("ssh -t administrator@207.254.31.242 \"ssh -t root@192.168.64.2 \\\"./tc.sh \(tcGroup) 'delay 20ms' ''\\\"\"").forceSuccess()
        
        let str = String(data: shellResult, encoding: .utf8)!
        
        print(str)
        return stage < 2
    }
}

/// Record the latencies of multiple paths over time. To see if outliers/spikes in latency appear on all paths at the same time or not
private func outlierTest() {
    runLatencyTestETH { paths in
        let path = paths.first(where: { $0.canonicalFingerprintShort == "47a96" })!

        return [path]
    } actionPerStage: { stage in
        let shouldContinue = stage < 10
        print("STAGE \(stage)")
        return shouldContinue
    }
}

private func plainETHConnection() {
    precondition(!isCloud())
    
    let conn = try! SCIONUDPConnection(clientConnectionTo: "16-ffaa:1:f04,192.168.64.1:1069", pathProcessor: SequentialPathProcessor(processors: [HellPreprocessor()]), receiveExtension: LatencyProbingReceiveExtension(), wantsToBeUsedForLatencyProbing: true)
    
    conn.listen().autoDisposableSink()
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        try! conn.send(data: Data())
    }
}

private func plainCloudConnection() {
    precondition(isCloud())
    
    let listener = try! SCIONUDPListener(listeningOn: 1069, pathProcessor: SequentialPathProcessor(processors: [HellPreprocessor()]), receiveExtension: LatencyProbingReceiveExtension(), wantsToBeUsedForLatencyProbing: true)
    
    listener.accept().autoDisposableSink(receiveValue:  { conn in
        conn.listen().autoDisposableSink()
    })
}

/// Record the latency of a single path over time. Increase latency artificially during each stage
private func increasingLatencyOnOnePathTest() {
    var tcGroup = 0
    runLatencyTestETH { paths in
        let path = paths.first(where: { $0.canonicalFingerprintShort == "04e5e" })!
        tcGroup = Int(path.tcIdentifier!.components(separatedBy: " ").last!)!
        
        return [path]
    } actionPerStage: { stage in
        let shellResult = shell("ssh -t administrator@207.254.31.242 \"ssh -t root@192.168.64.2 \\\"./tc.sh \(tcGroup) 'delay \(stage * 10)ms' ''\\\"\"").forceSuccess()
        
        let str = String(data: shellResult, encoding: .utf8)!
        
        print(str)
        
        return stage < 5
    }
}

/// Record the latency of a single path over time. Increase loss artificially during each stage
private func increasingLossOnOnePathTest() {
    var tcGroup = 0
    runLatencyTestETH { paths in
        let path = paths.first(where: { $0.canonicalFingerprintShort == "04e5e" })!
        tcGroup = Int(path.tcIdentifier!.components(separatedBy: " ").last!)!
        
        return [path]
    } actionPerStage: { stage in
        let shellResult = shell("ssh -t administrator@207.254.31.242 \"ssh -t root@192.168.64.2 \\\"./tc.sh \(tcGroup) 'loss \(pow(2, stage))%' ''\\\"\"").forceSuccess()
        
        let str = String(data: shellResult, encoding: .utf8)!
        
        print(str)
        
        return stage < 6
    }
}

private func startTestsCloud() {
    plainCloudConnection()
}

private func startTestsETH() {
    switch testCase {
    case .addedLatency:
        increasingLatencyOnOnePathTest()
    case .latencyCompare:
        multiplePathsLatencyTracing()
    case .addedLoss:
        increasingLossOnOnePathTest()
    case .exactLatencyPlot:
        outlierTest()
    default:
        fatalError("Invalid test case")
    }
}
