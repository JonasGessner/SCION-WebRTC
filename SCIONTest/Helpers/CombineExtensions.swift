//
//  CombineExtensions.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 01.04.21.
//

import Foundation
import Combine

extension Publisher {
    @discardableResult func autoDisposableSink(receiveCompletion: @escaping ((Subscribers.Completion<Self.Failure>) -> Void) = {_ in}, receiveValue: @escaping ((Self.Output) -> Void) = {_ in}) -> AnyCancellable {
        // This obejct is retained through strong references in the sink and handleEvents closures below
        var sharedCancellable: AnyCancellable?
        
        var end: (() -> Void)? = {
            sharedCancellable?.cancel()
            sharedCancellable = nil
        }
        
        let cancellable = handleEvents(receiveCancel: {
            end?()
            end = nil
        }).sink(receiveCompletion: { (completion) in
            receiveCompletion(completion)
            end?()
            end = nil
        }, receiveValue: receiveValue)
        
        sharedCancellable = cancellable
        
        return cancellable
    }
}

extension Publisher {
    func handleOutput(_ handler: @escaping (Output) -> Void) -> Publishers.HandleEvents<Self> {
        return handleEvents(receiveOutput: {
            handler($0)
        })
    }
    
    func tryHandleOutput(_ handler: @escaping (Output) throws -> Void) -> Publishers.TryMap<Self, Output> {
        return tryMap({
            try handler($0)
            return $0
        })
    }
    
    func handleError(_ handler: @escaping (Failure) -> Void) -> Publishers.HandleEvents<Self> {
        return handleEvents(receiveCompletion: { completion in
            switch completion {
            case .failure(let error):
                handler(error)
            default: break
            }
        })
    }
    
    func tryFlatMap<T, P>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Self.Output) throws -> P) -> AnyPublisher<T, Error> where T == P.Output, P : Publisher, Self.Failure == P.Failure, Self.Failure == Error {
        return tryMap { input -> P in
            return try transform(input)
        }
        .flatMap { pub in
            return pub
        }
        .eraseToAnyPublisher()
    }
}
