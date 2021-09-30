//
//  Setup.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 10.05.21.
//

import Foundation
// NOTE: malloc.go for arm64 on macOS is broken. It thinks there are only 33 bit address pointers but it should be 48. Needs to be MANUALLY PATCHED in malloc.go before running gomobile (heapAddrBits = 48).
import SCIONDarwin

struct TopologyParameters {
    let borderRouter: String
}

protocol TopologyTemplate {
    var name: String { get }
    func generateTopology(for parameters: TopologyParameters) -> String
}

fileprivate func scionHome() -> URL {
//    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
//    let documentsDirectory = paths[0]
//    return documentsDirectory
    
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let documentsDirectory = paths[0].deletingLastPathComponent().appendingPathComponent("scion-shizzle")
    if !FileManager.default.fileExists(atPath: documentsDirectory.path) {
        try! FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: false, attributes: nil)
    }
    return documentsDirectory
}

/// Class managing the SCION stack. It needs to be explicitly initialized.
final class SCIONStack: ObservableObject {
    static let shared = SCIONStack()
    
    @Published private(set) var initialized = false
    
    private let dispatcherQueue = DispatchQueue(label: "scion-dispatcher", qos: .default, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    private let sciondQueue = DispatchQueue(label: "sciond", qos: .default, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    
    private var initializing = false
    private let lock = NSLock()
    
    private init() {
    }
    
    func clearSciondCache() {
        try? FileManager.default.removeItem(at: scionHome().appendingPathComponent("sd.path.db"))
        try? FileManager.default.removeItem(at: scionHome().appendingPathComponent("sd.trust.db"))
    }
    
    /// Entry point to initialize the scion stack.
    func initScionStack(topology: String, certsDirectory: URL? = nil, cryptoDirectory: URL? = nil) throws {
        lock.lock()
        if initializing {
            fatalError("Duplicate initialization of Scion stack attempted")
        }
        initializing = true
        lock.unlock()
        
        // sockaddr_un has a character limit. Need as short of a socket path as possible. Domain sockets can only be opened inside the apps home directory or an app container. Other paths yield "operation not permitted". A path that is too long yields "accept invalid argument" error
        let socketPath = scionHome().appendingPathComponent("a")
        try? FileManager.default.removeItem(at: socketPath)
        
        if clearSciondCacheOnLaunch {
            self.clearSciondCache()
        }
        
        // The dispatcher and sciond need configs. They are created dynamically here
        let dispatcherConfig = """
                [dispatcher]
                id = "dispatcher"
                socket_file_mode = "0777"
                application_socket = "\(socketPath.path)"
                underlay_port = 30041
                
                [log.console]
                level = "debug"
                """
        
        let daemonConfig = """
                [general]
                id = "sd"
                config_dir = "\(scionHome().path)"
                reconnect_to_dispatcher = true
                
                [path_db]
                connection = "\(scionHome().appendingPathComponent("sd.path.db").path)"
                
                [trust_db]
                connection = "\(scionHome().appendingPathComponent("sd.trust.db").path)"
                
                [log.console]
                level = "debug"
                
                [sd]
                query_interval = "3h"
                """
        
        let dispPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("disp_config.toml")
        try dispatcherConfig.write(toFile: dispPath.path, atomically: true, encoding: .utf8)
        
        let daemonPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("daemon_config.toml")
        try daemonConfig.write(toFile: daemonPath.path, atomically: true, encoding: .utf8)
        
        // Need certs and topology file (https://docs.scionlab.org/content/config/setup_endhost.html)
        try? FileManager.default.removeItem(at: scionHome().appendingPathComponent("certs"))
        try FileManager.default.copyItem(at: certsDirectory ?? Bundle.main.url(forResource: "certs", withExtension: nil)!, to: scionHome().appendingPathComponent("certs"))
        
        let topologyPath = scionHome().appendingPathComponent("topology.json")
        try topology.write(to: topologyPath, atomically: true, encoding: .utf8)
        
        // Sets config file paths for dispatcher and sciond
        IosSetDaemonConfigPath(daemonPath.path)
        IosSetDispatcherConfigPath(dispPath.path)
        
        // Configures the appnet library to contact the dispatcher and sciond at the correct endpoints
        var error: NSError? = nil
        IosSetDispatcherSocket(socketPath.path, &error)
        if let error = error {
            throw error
        }
        IosSetSciondAddress("127.0.0.1:30255", &error)
        if let error = error {
            throw error
        }
        
        let sem = DispatchSemaphore(value: 0)
        
        // This only runs the dispatcher and the main init routine for a scion service
        sciondQueue.async {
            sem.signal()
            IosRunScion()
            
        }
        
        // And this just runs sciond
        dispatcherQueue.asyncAfter(deadline: .now() + 0.1) {
            sem.wait()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.initialized = true
            }
            
            IosRunSciond()
        }
    }
}
