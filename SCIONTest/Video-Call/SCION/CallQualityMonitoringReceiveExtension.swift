//
//  CallQualityMonitoringReceiveExtension.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 17.06.21.
//

import Foundation
import Combine
import CombineExt

fileprivate var lastKnownSeqID: UInt32 = 0

/// Receive extension for handling path penalties
struct CallQualityMonitoringReceiveExtension: SCIONConnectionReceiveExtension {
    static private let decoder = PropertyListDecoder()
    
    let publisher: AnyPublisher<PenaltyNotification, Never>
    
    private let subject = PassthroughSubject<PenaltyNotificationBatch, Never>()
    
    init() {
        publisher = subject
            .collect(.byTime(CallQualityMonitor.penaltyQueue, 0.5))
            .map({ notifications in
                notifications
                    .sorted(by: { $0.seqID < $1.seqID })
                    .drop(while: { $0.seqID <= lastKnownSeqID })
            })
            .flatMap({
                $0.publisher
            })
            .removeDuplicates()
            .handleOutput({
                print("Handling path penalty seqid \($0.seqID)")
                lastKnownSeqID = $0.seqID
            })
            .flatMap({
                $0.penalties.publisher
            })
            .eraseToAnyPublisher()
    }
    
    func handleReceive(of message: SCIONMessage, on connection: SCIONUDPConnection) -> SCIONMessage? {
        let data = message.data
        
        if data.starts(with: penaltyNotificationHeader) {
            CallQualityMonitor.penaltyQueue.async {
                do {
                    let penalties = try CallQualityMonitoringReceiveExtension.decoder.decode(PenaltyNotificationBatch.self, from: data[penaltyNotificationHeader.count...])
                    
                    subject.send(penalties)
                }
                catch {
                    print("Failed to decode path penalty notifications! \(error)")
                }
            }
            
            return nil
        }
        
        return message
    }
}
