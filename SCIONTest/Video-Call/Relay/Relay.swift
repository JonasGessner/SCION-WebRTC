//
//  Relay.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 31.03.21.
//

import Foundation
import Combine
import CombineExt

protocol DataContainer {
    var data: Data { get }
}

extension Data: DataContainer {
    var data: Data {
        return self
    }
}

extension SCIONMessage: DataContainer {
    var data: Data {
        return contents
    }
}

/// A collection of connections that transport video call media streams. Two relays can be connected to each other so that they relay traffic through each other. This is used to set up the capturing UDP connections and relay traffic through the SCION relay connections over the Internet to the other peer.
protocol Relay: AnyObject {
    associatedtype Channel
    associatedtype Connection: Equatable
    associatedtype Message: DataContainer
    
    var channelCount: Int { get }
    var channels: [(ChannelType, Channel)] { get }
    var connections: [[(Connection, AnyPublisher<Message, Error>)]] { get }
    
    /// Publishes the first available connection per channel to every subscriber as soon as it becomes available
    var firstConnectionPublisher: [AnyPublisher<(Connection, AnyPublisher<Message, Error>), Never>] { get }
    
    func send(data: Data, through connection: Connection) throws
    
    func close()
}

extension Relay {
    var channelCount: Int {
        return channels.count
    }
}

#if GATHER_RELAY_FREEZE_STATS
final class RelayStatistics: ObservableObject {
    static let shared = RelayStatistics()
    
    static let queue = DispatchQueue(label: "relay stats", qos: .utility, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    private init() {}
    
    struct Report {
        let metric = TimedMetric<Int>()
        
        private(set) var averageSpeed: Double = 0
        
        private(set) var freezes = [(start: Date, duration: TimeInterval)]()
        
        private var lastCountDate = Date.distantFuture
        
        let smoothingFactor = 0.1
        
        mutating func add(count: Int) {
            let now = Date()
            if now.timeIntervalSince(lastCountDate) > 0.4 {
                freezes.append((lastCountDate, now.timeIntervalSince(lastCountDate)))
            }
            lastCountDate = now
            
            metric.add(entry: count)
            let lastSpeed = metric.calculateAverage(over: 0.2, relative: false, timeAverage: true)
            
            averageSpeed = smoothingFactor * lastSpeed + (1 - smoothingFactor) * averageSpeed
            
            metric.purge(anythingOlderThan: 1)
        }
    }
    
    /* @Published */private(set) var stats = [((AnyObject, ChannelType), Report)]()
    
    func register(relay: AnyObject, channelType: ChannelType) -> Int {
        stats.append(((relay, channelType), Report()))
        return stats.count - 1
    }
    
    func add(count: Int, at index: Int) {
        var (relay, report) = stats[index]
        report.add(count: count)
        stats[index] = (relay, report)
    }
}
#endif

extension Relay {
    /// Only works with one connection per channel!
    /// onConnect: (relayed channel type, channel index, connection, relay channel indices, relay connections)
    @_specialize(where R==SCIONVideoCallRelayListener, Self==UDPVideoCallRelayListener)
    @_specialize(where R==SCIONVideoCallRelayClient, Self==UDPVideoCallRelayListener)
    @_specialize(where R==UDPVideoCallRelayListener, Self==UDPVideoCallRelayListener)
    @_specialize(where R==UDPVideoCallRelayClient, Self==UDPVideoCallRelayListener)
    func pipe<R: Relay>(through relay: R, onConnect: @escaping (ChannelType, Int, Connection, [(Int, R.Connection)]) -> Void = {_, _, _, _ in}) {
        zip(channels.map({ $0.0 }), firstConnectionPublisher).enumerated().forEach { index, tup in
            let (type, pub) = tup
            var finalRelays: [R.Connection]?

            #if GATHER_RELAY_FREEZE_STATS
            let statsIndex = RelayStatistics.shared.register(relay: self, channelType: type)
            #endif
            
            let allMatchingRelayChannelIndices = relay.channels.enumerated().filter({ $0.element.0 == type }).map({ $0.offset })
            
            pub
                .autoDisposableSink(receiveValue: { connection, messagePub in
                    messagePub
                        .autoDisposableSink(receiveValue: { message in
                        if let finalRelays = finalRelays {
                            #if GATHER_RELAY_FREEZE_STATS
                            RelayStatistics.queue.async {
                                RelayStatistics.shared.add(count: message.data.count, at: statsIndex)
                            }
                            #endif
                            finalRelays.forEach { relayConnection in
                                let data = message.data
                                
                                do {
                                    try relay.send(data: data, through: relayConnection)
                                }
                                catch {
                                    print("SCION Relay Error \(error)")
                                }
                            }
                        }
                        else {
                            do {
                                let relays: [R.Connection] = try allMatchingRelayChannelIndices.map { index -> R.Connection in
                                    let connections = relay.connections[index]
                                    
                                    if connections.isEmpty {
                                        print("Not relaying, no client to relay to. From \(self) to \(relay)")
                                        throw SCIONError.general
                                    }
                                    else if connections.count > 1 {
                                        fatalError("Multiple connections available. Can only pipe into a single relay connection")
                                    }
                                    
                                    let relayConnection = connections[0].0
                                    
                                    return relayConnection
                                }
                                
                                finalRelays = relays
                                
                                onConnect(type, index, connection, Array(zip(allMatchingRelayChannelIndices, relays)))
                            }
                            catch {
                                print("Connect failed in relay \(error)")
                            }
                        }
                    })
                })

        }
    }
}

// Type erasure for relays
enum AnyRelayEndpoint<Server: Relay, Client: Relay> {
    case server(Server)
    case client(Client)
}

enum AnyRelay {
    case udp(AnyRelayEndpoint<UDPVideoCallRelayListener, UDPVideoCallRelayClient>)
    case scion(AnyRelayEndpoint<SCIONVideoCallRelayListener, SCIONVideoCallRelayClient>)
}
