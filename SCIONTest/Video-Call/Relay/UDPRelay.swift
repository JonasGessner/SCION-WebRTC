//
//  UDPRelay.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 31.03.21.
//

import Foundation
import Network
import Combine
import CombineExt

// This file contains video call relays for UDP. These relays realize the capturing connections (as they are called in the thesis report)

#if GATHER_UDP_RELAY_COUNTERS
fileprivate struct Stats {
    static let requestLock = NSLock()
    static let completedLock = NSLock()
    static var requested = 0
    static var completed = 0
}
#endif

extension Relay where Connection == NWConnection {
    func send(data: Data, through connection: Connection) throws {
        #if GATHER_UDP_RELAY_COUNTERS
        Stats.requestLock.lock()
        Stats.requested += 1
        Stats.requestLock.unlock()
        #endif
        
        connection.send(content: data, completion: .contentProcessed({ _ in
            #if GATHER_UDP_RELAY_COUNTERS
            Stats.completedLock.lock()
            Stats.completed += 1
            Stats.completedLock.unlock()


            if (Stats.completed % 5000) == 10 {
                print("UDP stats: requested \(Stats.requested) completed \(Stats.completed) diff \(Stats.requested - Stats.completed)")
            }
            #endif
        }))
    }
}

extension NWConnection: Equatable {
    public static func == (lhs: NWConnection, rhs: NWConnection) -> Bool {
        return lhs === rhs
    }
}

final class UDPVideoCallRelayListener: Relay {
    let channels: [(ChannelType, NWListener)]
    
    private(set) var connections: [[(NWConnection, AnyPublisher<Data, Error>)]]
    
    private let lock = NSLock()
    
    let firstConnectionPublisher: [AnyPublisher<(NWConnection, AnyPublisher<Data, Error>), Never>]
    private let firstConnectionSubjects: [ReplaySubject<(Connection, AnyPublisher<Message, Error>), Never>]
    
    private var subscriptions = Set<AnyCancellable>()
    
    /// Parameters to use for a remote relay server that relays the WebRTC traffic over wifi to the other peer
    static let wifiRelayParameters: NWParameters = {
        // TODO: turn off ipv6
        let params = NWParameters.init(dtls: nil)
        params.requiredInterfaceType = .wifi
        
        return params
    }()
    
    /// Parameters to use for the local adapter that catches all the WebRTC traffic
    static let localhostAdapterParameters: NWParameters = {
        // TODO: turn off ipv6
        let params = NWParameters.init(dtls: nil)
        params.requiredInterfaceType = .loopback
        params.acceptLocalOnly = true
        
        return params
    }()
    
    static func acceptLoopbackOnlyPredicate(_ connection: NWConnection) -> Bool {
        if case let .hostPort(host: .ipv4(address), port: _) = connection.endpoint,
           address.isLoopback {
            return true
        }
        
        return false
    }
    
    private let queue: DispatchQueue
    private let listenerQueue: DispatchQueue
    
    /// Waits to return until all listeners are ready or an error occurs
    init(channelTypes: [ChannelType], acceptPredicate: @escaping (NWConnection) -> Bool = { _ in true }, parameters: NWParameters) throws {
        connections = [[(NWConnection, AnyPublisher<Data, Error>)]](repeating: [], count: channelTypes.count)
        
        let subjects = (0..<channelTypes.count).map { _ in ReplaySubject<(NWConnection, AnyPublisher<Data, Error>), Never>(bufferSize: 1) }
        firstConnectionSubjects = subjects
        firstConnectionPublisher = subjects.map { $0.eraseToAnyPublisher() }
        
        let semaphore = DispatchSemaphore(value: 1)
        
        channels = channelTypes.map { type -> (ChannelType, NWListener) in
            do {
                let port = UInt16.random(in: 1025..<UInt16.max)
                
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port.init(rawValue: port)!)
                
                listener.stateUpdateHandler = { state in
                    // TODO: handle errors
                    if state == .ready {
                        semaphore.signal()
                    }
                    print("Udp listener new state \(state)")
                }
                
                return (type, listener)
            }
            catch {
                // TODO: handle port conflicts
                fatalError(error.localizedDescription)
            }
        }
        
        let queue = DispatchQueue(label: "conn", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .workItem, target: nil)
        self.queue = queue
        
        let listenerQueue = DispatchQueue(label: "listener", qos: .default, attributes: [], autoreleaseFrequency: .workItem, target: nil)
        self.listenerQueue = listenerQueue
        
        // Need to do this separately because cant reference self before initializing all members
        for (index, (subject, (_, listener))) in zip(subjects, channels).enumerated() {
            var firstConnection = true
            
            listener.newConnectionHandler = { [weak self, weak subject] conn in
                guard acceptPredicate(conn) else {
                    print("Rejecting connection from endpoint: \(conn)")
                    return
                }
                
                var listening = false
                conn.stateUpdateHandler = { [weak self, weak conn, weak subject] state in
                    guard let conn = conn else { return }
                    
                    // TOOD: error handling
                    if state == .ready {
                        if listening {
                            print("ALRWEADY LISTENING")
                            return
                        }
                        listening = true
                        
                        let pub = conn.listenForever(/*via: forwardingQueue*/)
                            .compactMap({ result -> Data? in
                                switch result {
                                // TODO: handle errors
                                case .failure(let error):
                                    print("UDP Listen Error \(error)")
                                    return nil
                                case .success(let data):
                                    return data
                                }
                            })
                            .setFailureType(to: Error.self)
                            .share()
                            .eraseToAnyPublisher()
                        
                        self?.lock.lock()
                        if firstConnection {
                            firstConnection = false
                            self?.lock.unlock()
                            if let s = subject {
                                s.send((conn, pub))
                                s.send(completion: .finished)
                            }
                        }
                        else {
                            self?.lock.unlock()
                        }
                        
                        self?.lock.lock()
                        self?.connections[index].append((conn, pub))
                        self?.lock.unlock()
                    }

                    print("Incoming udp conn new state \(state)")
                }
                
                conn.start(queue: queue)
            }
            
            listener.start(queue: listenerQueue)
        }
        
        for _ in 0..<channelCount {
            semaphore.wait()
        }
    }
    
    func close() {
        channels.forEach({
            $0.1.cancel()
        })
        firstConnectionSubjects.forEach({
            $0.send(completion: .finished)
        })
        connections.flatMap({ $0 }).forEach({ con, _ in
            con.cancel()
        })
    }
    
    deinit {
        close()
    }
}

final class UDPVideoCallRelayClient: Relay {
    let channels: [(ChannelType, NWConnection)]
    
    let connections: [[(NWConnection, AnyPublisher<Data, Error>)]]
    let firstConnectionPublisher: [AnyPublisher<(NWConnection, AnyPublisher<Data, Error>), Never>]
    
    private var subscriptions = Set<AnyCancellable>()
    
    private let queue: DispatchQueue
//    private let forwardingQueue: DispatchQueue
    
    /// Waits to return until all connections are ready or an error occurs
    init(serverInfo: RelayServerInfo) throws {
        // THis should probably be a fatal error – asserts are noops in non-debug builds
        assert(serverInfo.networkProtocol == .udp)

        guard let address = IPv4Address(serverInfo.serverAddress) else {
            fatalError() // TODO handle errors
        }
        
        let semaphore = DispatchSemaphore(value: 1)
        
        channels = serverInfo.endpoints.enumerated().map { index, endpoint in
            let params = NWParameters.init(dtls: nil)
            params.requiredInterfaceType = .wifi
            
            let conn = NWConnection(host: .ipv4(address), port: .init(integerLiteral: endpoint.port), using: params)
            
            return (endpoint.channelType, conn)
        }
        
        let queue = DispatchQueue(label: "conn", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .workItem, target: nil)
        self.queue = queue
//        let forwardingQueue = DispatchQueue(label: "conn-fq", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .workItem, target: nil)
//        self.forwardingQueue = forwardingQueue
        
        channels.forEach { _, conn in
            conn.stateUpdateHandler = { state in
                // TODO: handle errors
                if state == .ready {
                    semaphore.signal()
                }
                print("Outgoing udp conn state \(state)")
            }
            
            conn.start(queue: queue)
        }
        
        for _ in 0..<channels.count {
            semaphore.wait()
        }
        
        connections = channels.map { _, conn in
            let pub = conn.listenForever(/*via: forwardingQueue*/)
                .compactMap({ result -> Data? in
                    switch result {
                    // TODO: handle errors
                    case .failure(let error):
                        print("UDP Listen Error \(error)")
                        return nil
                    case .success(let data):
                        return data
                    }
                })
                .setFailureType(to: Error.self)
                .share()
                .eraseToAnyPublisher()
            
            return [(conn, pub)]
        }
        
        firstConnectionPublisher = connections.map { Just($0[0]).eraseToAnyPublisher() }
    }
    
    func close() {
        channels.forEach({
            $0.1.cancel()
        })
    }
    
    deinit {
        close()
    }
}
