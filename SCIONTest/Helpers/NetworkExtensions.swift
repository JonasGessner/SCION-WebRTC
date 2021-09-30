//
//  NetworkExtensions.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 31.03.21.
//

import Foundation
import Network
import Combine

extension NWConnection {
    func listenForever() -> AnyPublisher<Result<Data, Error>, Never> {
        let subject = PassthroughSubject<Result<Data, Error>, Never>()
        
        var cancelled = false
        
        func receiveForever(on conn: NWConnection) {
            receiveMessage { [weak conn] data, _, _, error in
                guard !cancelled, let conn = conn else { return }
                switch conn.state {
                case .cancelled:
                    cancelled = true
                    subject.send(completion: .finished)
                    return
                case .failed(_):
                    cancelled = true
                    subject.send(completion: .finished)
                    return
                default: break
                }
                receiveForever(on: conn)
                
                if let error = error {
                    subject.send(.failure(error))
                }
                else if let data = data {
                    subject.send(.success(data))
                }
            }
        }
        
        receiveForever(on: self)
        
        return subject.handleEvents(receiveCancel: { cancelled = true; subject.send(completion: .finished) }).eraseToAnyPublisher()
    }
}
