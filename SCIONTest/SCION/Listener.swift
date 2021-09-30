//
//  Listener.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 29.09.21.
//

import Foundation
import Combine
import SCIONDarwin

final class SCIONUDPListener {
    let appnetConnection: IosListener
    let readBuffer: NSMutableData
    
    private var pullSubject: PassthroughSubject<SCIONMessage, Never>?
    
    let port: UInt16
    
    var localAddress: SCIONAddress? {
        return SCIONAddress(appnetAddress: appnetConnection.getLocalAddress()!)
    }
    
    let queue = DispatchQueue(label: "scion listener", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    //    let combineQueue = DispatchQueue(label: "scion client", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    
    var pathProcessor: PathProcessor
    var receiveExtension: SCIONConnectionReceiveExtension
    var wantsToBeUsedForLatencyProbing: Bool
    
    private let pullLock = NSLock()
    
    private(set) var closed = false
    
    /// Server
    init(listeningOn port: UInt16, readBufferSize: Int = 32 * 1024 * 1024, pathProcessor: PathProcessor, receiveExtension: SCIONConnectionReceiveExtension = LatencyProbingReceiveExtension(), wantsToBeUsedForLatencyProbing: Bool) throws {
        var err: NSError? = nil
        guard let res = IosListenUDP(Int(port), &err),
              let buf = NSMutableData(length: readBufferSize)
        else {
            throw err ?? SCIONError.general
        }
        appnetConnection = res
        if let error = err {
            throw error
        }
        
        self.pathProcessor = pathProcessor
        self.receiveExtension = receiveExtension
        readBuffer = buf
        self.port = port
        self.wantsToBeUsedForLatencyProbing = wantsToBeUsedForLatencyProbing
    }
    
    func pull() -> AnyPublisher<SCIONMessage, Never> {
        pullLock.lock()
        defer { pullLock.unlock() }
        
        if let subject = self.pullSubject {
            return subject.eraseToAnyPublisher()
        }
        
        let subject = PassthroughSubject<SCIONMessage, Never>()
        pullSubject = subject
        
        queue.async {
            while !self.closed {
                // The queue can't autorelease anything because this operation is an infinite loop and the queue would only autorelease after the operation completed. Hence we have to manually do an autorelease
                autoreleasepool {
                    do {
                        let (data, source, path) = try self.read()
                        
                        let message = SCIONMessage(contents: data, source: source, replyPath: path)
                        
                        subject.send(message)
                    }
                    catch {
                        print("Read error! \(error.localizedDescription)")
                    }
                }
            }
            
            subject.send(completion: .finished)
        }
        
        return subject.eraseToAnyPublisher()
    }
    
    private var knownConnections = [SCIONAddress: SCIONUDPConnection]()
    private var connectionSubscriptions = Set<AnyCancellable>()
    
    /// Extra abstraction to get connection handles. Not useful for raw udp traffic, very useful for connection-oriented traffic built on udp (compare: Network framework)
    func accept(mapPathProcessor: @escaping (PathProcessor) -> (PathProcessor, (SCIONUDPConnection?) -> Void) = { ($0, {_ in}) }) -> AnyPublisher<SCIONUDPConnection, Never> {
        pull()
        // Capture self weakly, but then push it through these operators as a strong reference
            .compactMap({ [weak self] message -> (SCIONMessage, SCIONUDPListener)? in
                guard let self = self else { return nil }
                return (message, self)
            })
            .filter({
                return $1.knownConnections[$0.source] == nil
            })
            .compactMap({ message, server in
                // A bit of a mess here. The first time we know that a new client has connected we are already presented with the first data packet sent by that client. But there is no subscriber yet for packets coming from this client, we are literally creating the publisher for packets from that client here. But the first data packet from the client has already been published by the pull publisher. Hence we need to re-publish it in a new publisher, and then push all subsequent packages from this client through that publisher as well.
                let dataSubject = CurrentValueSubject<SCIONMessage, Never>(message)
                let address = message.source
                
                server.pull()
                    .filter({ $0.source == address })
                    .subscribe(dataSubject)
                    .store(in: &server.connectionSubscriptions)
                
                let (processor, finally) = mapPathProcessor(server.pathProcessor)
                
                do {
                    let policy = SCIONPathPolicy()
                    
                    let senderConnection = try server.appnetConnection.makeConnection(toRemote: address.appnetAddress, policyFilter: policy)
                    
                    let endpoint = SCIONUDPConnection.LocalEndpoint.listener(senderConnection, dataSubject.eraseToAnyPublisher(), dataSubject)
                    
                    let connection = SCIONUDPConnection(localEndpoint: endpoint, pathPolicy: policy, pathProcessor: processor, receiveExtension: server.receiveExtension, wantsToBeUsedForLatencyProbing: server.wantsToBeUsedForLatencyProbing)
                    
                    finally(connection)
                    
                    server.knownConnections[address] = connection
                    
                    return connection
                }
                catch {
                    finally(nil)
                    
                    print("Failed to create new connection handle \(error)")
                }
                
                return nil
            })
            .share()
            .eraseToAnyPublisher()
    }
    
    func close() {
        closed = true
        appnetConnection.close()
        knownConnections.values.forEach({
            $0.close()
        })
        connectionSubscriptions.forEach({
            $0.cancel()
        })
        connectionSubscriptions.removeAll()
        knownConnections.removeAll()
        pullSubject?.send(completion: .finished)
    }
    
    private func read(into data: NSMutableData) throws -> (Int, SCIONAddress, SCIONPathSource?) {
        // Is nil data really an error?
        guard let result = appnetConnection.read(data as Data?) else {
            throw SCIONError.general
        }
        
        //        let start = CFAbsoluteTimeGetCurrent()
        //        defer {
        //            let took = CFAbsoluteTimeGetCurrent() - start
        //            if took > 0.001 {
        //                print("Slow read \(took)")
        //            }
        //        }
        //
        if let error = result.err {
            throw error
        }
        
        let returnPath = result.path.map { SCIONPathSource(underlying: $0) }
        
        return (result.bytesRead, SCIONAddress(appnetAddress: result.source!), returnPath)
    }
    
    private func read() throws -> (Data, SCIONAddress, SCIONPathSource?) {
        let (readBytes, sourceAddress, sourcePath) = try read(into: readBuffer)
        let data = Data(bytes: readBuffer.mutableBytes, count: readBytes)
        return (data, sourceAddress, sourcePath)
    }
}

extension SCIONUDPListener: Identifiable, Equatable, Hashable {
    static func == (lhs: SCIONUDPListener, rhs: SCIONUDPListener) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        hasher.combine(ptr)
    }
    
    var id: String {
        return "\(Unmanaged.passUnretained(self).toOpaque())"
    }
}

extension IosConnection: Identifiable {
    public var id: String {
        return "\(Unmanaged.passUnretained(self).toOpaque())"
    }
}
