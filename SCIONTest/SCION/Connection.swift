//
//  Connection.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 10.05.21.
//

import Foundation
import SCIONDarwin
import Combine

fileprivate final class PathObserver: NSObject, IosSelectorObserverProtocol {
    fileprivate static let pathObserverQueue = DispatchQueue(label: "path down observer", qos: .default, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    
    fileprivate override init() {
        pathsWillChangePublisher = pathsWillChangeSubject
            .receive(on: PathObserver.pathObserverQueue)
            .eraseToAnyPublisher()
        
        pathsDidChangePublisher = pathsDidChangeSubject
            .receive(on: PathObserver.pathObserverQueue)
            .eraseToAnyPublisher()
        
        pathDidGoDownPublisher = pathDidGoDownSubject
            .receive(on: PathObserver.pathObserverQueue)
            .map(\.wrapped)
            .eraseToAnyPublisher()
        
        super.init()
    }
    
    func close() {
        pathsWillChangeSubject.send(completion: .finished)
        pathsDidChangeSubject.send(completion: .finished)
        pathDidGoDownSubject.send(completion: .finished)
    }
    
    func pathsDidChange() {
        pathsDidChangeSubject.send()
    }
    
    func pathsWillChange() {
        pathsWillChangeSubject.send()
    }
    
    func pathDidGoDown(_ path: IosPath?) {
        guard let path = path else { return }
        
        pathDidGoDownSubject.send(path)
    }
    
    private let pathsWillChangeSubject = PassthroughSubject<Void, Never>()
    private let pathsDidChangeSubject = PassthroughSubject<Void, Never>()
    private let pathDidGoDownSubject = PassthroughSubject<IosPath, Never>()
    
    let pathsWillChangePublisher: AnyPublisher<Void, Never>
    let pathsDidChangePublisher: AnyPublisher<Void, Never>
    let pathDidGoDownPublisher: AnyPublisher<SCIONPath, Never>
}

extension PathProcessor {
    func joinFlat(with other: PathProcessor) -> SequentialPathProcessor {
        let finalProcessor: SequentialPathProcessor
        if let sequential = self as? SequentialPathProcessor {
            finalProcessor = sequential.byAdding(additional: [other])
        }
        else {
            finalProcessor = SequentialPathProcessor(processors: [self, other])
        }
        return finalProcessor
    }
    
    func joinFlatStateful(with other: PathProcessor) -> RootPathProcessor {
        let finalProcessor: RootPathProcessor
        if let sequential = self as? SequentialPathProcessor {
            finalProcessor = RootPathProcessor(processors: sequential.processors + CollectionOfOne(other))
        }
        else {
            finalProcessor = RootPathProcessor(processors: [self, other])
        }
        return finalProcessor
    }
}


final class SCIONUDPConnection: Equatable, Hashable, Identifiable, ObservableObject {
    private static let deferredActionsQueue = DispatchQueue(label: "deferred connection actions", qos: .default, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    
    static func == (lhs: SCIONUDPConnection, rhs: SCIONUDPConnection) -> Bool {
        return lhs.localEndpoint == rhs.localEndpoint
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(localEndpoint)
    }
    
    private(set) var closed = false
    
    func close() {
        closed = true
        switch localEndpoint {
        case .client(let c):
            c.close()
        case .listener(_, _, let sub):
            sub.send(completion: .finished)
        }
        subs.forEach({
            $0.cancel()
        })
        subs.removeAll()
        observer?.close()
        observer = nil
        pathPolicyBridge = nil
        activePathProcessorSubscription = nil
        failoverSub = nil
        failoverPublisher.send(completion: .finished)
    }
    
    enum LocalEndpoint: Equatable, Hashable, Identifiable {
        case client(SCIONClient)
        case listener(IosConnection, AnyPublisher<SCIONMessage, Never>, CurrentValueSubject<SCIONMessage, Never>)
        
        static func == (lhs: LocalEndpoint, rhs: LocalEndpoint) -> Bool {
            switch lhs {
            case .listener(let lConn, _, _):
                switch rhs {
                case .listener(let rConn, _, _):
                    return lConn === rConn
                default:
                    return false
                }
            case .client(let lClient):
                switch rhs {
                case .client(let rClient):
                    return lClient == rClient
                default:
                    return false
                }
            }
        }
        
        func hash(into hasher: inout Hasher) {
            switch self {
            case .listener(let conn, _, _):
                hasher.combine(conn)
            case .client(let client):
                hasher.combine(client)
            }
        }
        
        var id: String {
            switch self {
            case .listener(let conn, _, _):
                return conn.id
            case .client(let client):
                return client.id
            }
        }
    }
    
    var id: String {
        return localEndpoint.id
    }
    
    private let localEndpoint: LocalEndpoint
    
    private var mirroring = false
    @Published private(set) var mirrorReplyPath: SCIONPathSource? {
        didSet {
            updateEffectivePath()
        }
    }
    
    private let conn: IosConnection
    private let foreignConnection: Bool
    
    private var activePathProcessorSubscription: AnyCancellable?
    
    private weak var observer: PathObserver?
    
    var receiveExtension: SCIONConnectionReceiveExtension?
    
    private var lastPathDownNotificationTimestamps: [SCIONPath: Date] = [:]
    
    // Rationale why considerAsFailover is false: considerAsFailover is used to apply penalties to similar paths of a path that was deemed "bad" and which was replaced with another path ("failover"). On path down notifications, we get notified of all paths that are down already – hence we don't need to try and estimate which paths might share the bad QoS by looking at the degree that they are disjoint. We already know exactly which paths are down and which are not.
    private let pathDownPunisher = PathPenalizer(considerAsFailover: false)
    private(set) var fullPathProcessor: RootPathProcessor
    private(set) var failoverSub: AnyCancellable?
    
    let wantsToBeUsedForLatencyProbing: Bool
    
    private var subs = Set<AnyCancellable>()
    
    // Determines whether a given message should be used to potentially update the mirrorReplyPath
    var mirrorReplyPathFilter: (SCIONMessage) -> Bool = {_ in true}
    
    let failoverPublisher = PassthroughSubject<(old: SCIONPath, new: SCIONPath), Never>()
    
    init(localEndpoint: LocalEndpoint, pathPolicy: SCIONPathPolicy, pathProcessor: PathProcessor, receiveExtension: SCIONConnectionReceiveExtension? = LatencyProbingReceiveExtension(), wantsToBeUsedForLatencyProbing: Bool) {
        self.localEndpoint = localEndpoint
        
        self.pathProcessor = pathProcessor
        self.pathPolicyBridge = pathPolicy
        let fullProcessor = pathProcessor.joinFlatStateful(with: pathDownPunisher)
        self.fullPathProcessor = fullProcessor
        self.pathPolicyBridge.processor = fullPathProcessor
        
        self.receiveExtension = receiveExtension
        self.wantsToBeUsedForLatencyProbing = wantsToBeUsedForLatencyProbing
        
        switch localEndpoint {
        case .client(let client):
            conn = client.appnetConnection
        case .listener(let _conn, _, _):
            conn = _conn
        }
        
        let observer = PathObserver()
        self.observer = observer
        
        switch localEndpoint {
        case .listener(let conn, _, _):
            remoteAddress = SCIONAddress(appnetAddress: conn.getRemoteAddress()!)
            localAddress = SCIONAddress(appnetAddress: conn.getLocalAddress()!)
            
            paths = conn.getPaths()?.wrapped ?? []
            pathProcessorChosenPath = conn.getCurrentPath()?.wrapped
            conn.setPathSelectorObserver(observer)
        case .client(let client):
            remoteAddress = client.remoteAddress
            localAddress = SCIONAddress(appnetAddress: client.appnetConnection.getLocalAddress()!)
            
            paths = client.appnetConnection.getPaths()?.wrapped ?? []
            pathProcessorChosenPath = client.appnetConnection.getCurrentPath()?.wrapped
            client.appnetConnection.setPathSelectorObserver(observer)
        }
        
        foreignConnection = localAddress.isInForeignAS(to: remoteAddress)
        mirroring = (pathProcessor is MirrorPathSorter) && foreignConnection
        
        observer.pathsDidChangePublisher
            // Do this translation work on the publishing queue
            .compactMap({ [weak self] _ -> ([SCIONPath], SCIONPath?)? in
                guard let self = self else { return nil }
                
                let paths = self.conn.getPaths()?.wrapped ?? []
                let pathProcessorChosenPath = self.conn.getCurrentPath()?.wrapped

                return (paths, pathProcessorChosenPath)
            })
            // Then only switch to the main queue to assign the @Published properties
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] paths, pathProcessorChosenPath in
                guard let self = self else { return }
                
                self.paths = paths
                self.pathProcessorChosenPath = pathProcessorChosenPath
            })
            .store(in: &subs)
        
        // This chain debounces path down notifications for 20 seconds, meaning that any path down notification within 20 seconds of a prior path down notification (which wasn't ignored) is ignored
        observer.pathDidGoDownPublisher
            .compactMap({ [weak self] path -> (SCIONUDPConnection, SCIONPath, Date)? in
                guard let self = self else { return nil }
                
                return (self, path, Date())
            })
            .filter { `self`, path, date in
                date.timeIntervalSince(self.lastPathDownNotificationTimestamps[path, default: .distantPast]) > 20.0
            }
            .handleOutput { `self`, path, date in
                self.lastPathDownNotificationTimestamps[path] = date
            }
            .collect(.byTime(SCIONUDPConnection.deferredActionsQueue, 0.1))
            .sink { values in
                guard let `self` = values.first?.0 else { return }
                
                self.pathDownPunisher.mutating(by: { current in
                    var mut = current
                    for (_, path, _) in values {
                        mut[path, default: 0] += 1
                        print("Path down: \(path)")
                    }
                    return mut
                }, countsAsFailover: false)
            }
            .store(in: &subs)
        
        configureActivePathProcessor()
        updateEffectivePath()
    }
    
    convenience init(clientConnectionTo remote: String, readBufferSize: Int = 32 * 1024 * 1024, pathProcessor: PathProcessor, receiveExtension: SCIONConnectionReceiveExtension? = LatencyProbingReceiveExtension(), wantsToBeUsedForLatencyProbing: Bool) throws {
        let policy = SCIONPathPolicy()
        
        let client = try SCIONClient(connectingTo: remote, readBufferSize: readBufferSize, policy: policy)
        
        self.init(localEndpoint: .client(client), pathPolicy: policy, pathProcessor: pathProcessor, receiveExtension: receiveExtension, wantsToBeUsedForLatencyProbing: wantsToBeUsedForLatencyProbing)
    }
    
    func listen() -> AnyPublisher<SCIONMessage, Never> {
        let basic: AnyPublisher<SCIONMessage, Never>
        
        switch localEndpoint {
        case .client(let client):
            basic = client.pull()
        case .listener(_, let pub, _):
            basic = pub
        }
        
        // TODO: This publisher should report errors. Output type should be Result<SCIONMessage, Error>
        return
            basic
            // Let the active path processor intercept the message
            .filter { msg in
                return self.fullPathProcessor.handleReceive(of: msg, on: self)
            }
            // Let the receive extension intercept the message
            .compactMap { msg -> SCIONMessage? in
                let final: SCIONMessage?
                if let receiveExtension = self.receiveExtension {
                    final = receiveExtension.handleReceive(of: msg, on: self)
                }
                else {
                    final = msg
                }
                
                return final
            }
            // Non intercepted messages finally update the mirror reply path
            .handleOutput({ msg in
                if self.mirrorReplyPathFilter(msg) && (msg.replyPath != self.mirrorReplyPath || (self.mirrorReplyPath?.canRecoverMetadata() ?? false)) {
                    print("Updating mirror reply path")
                    DispatchQueue.main.async {
                        self.mirrorReplyPath = msg.replyPath
                    }
                }
            })
            .share()
            .eraseToAnyPublisher()
    }
    
    @discardableResult func send(data: Data, path: SCIONPath?, wantUsedPath: Bool = false) throws -> (SCIONPath?, Int) {
        let res: IosWriteResult!
        
        if let path = path {
            res = conn.writePath(data, path: path.appnetPath)
        }
        else {
            res = conn.write(data, wantUsedPath: wantUsedPath)
        }
        
        if let err = res.err {
            throw err
        }
        
        let usedPath = wantUsedPath ? (path ?? res.path.map { $0.wrapped }) : nil
        
        return (usedPath, res.bytesWritten)
    }
    
    @discardableResult func send(data: Data, path: SCIONPathSource?, wantUsedPath: Bool = false) throws -> (SCIONPathSource?, Int) {
        let res: IosWriteResult!
        
        if let path = path {
            res = conn.writePath(data, path: path.underlying)
        }
        else {
            res = conn.write(data, wantUsedPath: wantUsedPath)
        }
        
        if let err = res.err {
            throw err
        }
        
        let usedPath = wantUsedPath ? (path ?? res.path.map { SCIONPathSource(underlying: $0) }) : nil
        
        return (usedPath, res.bytesWritten)
    }
    
    @discardableResult func send(data: Data, wantUsedPath: Bool = false) throws -> (SCIONPathSource?, Int) {
        if mirroring {
            guard let mirrorReplyPath = self.mirrorReplyPath else {
                throw SCIONError.general // TODO: No mirror reply path set error
            }
            return try send(data: data, path: mirrorReplyPath, wantUsedPath: wantUsedPath)
        }
        else {
            return try send(data: data, path: fixedPathSource, wantUsedPath: wantUsedPath)
        }
    }
    
    let remoteAddress: SCIONAddress
    let localAddress: SCIONAddress
    
    /// Unprocessed paths
    var rootPaths: [SCIONPath] {
        return fullPathProcessor.rootPaths
    }
    
    @Published private(set) var paths: [SCIONPath] {
        didSet {
            //            print("Paths changed: \(paths.map({ $0.canonicalFingerprintShort }))")
        }
    }
    
    private func updateEffectivePath() {
        DispatchQueue.main.async {
            if let fixed = self.fixedPath {
                self.effectivePath = fixed
            }
            else if self.mirroring {
                self.effectivePath = self.mirrorReplyPath?.path
            }
            else {
                self.effectivePath = self.pathProcessorChosenPath
            }
        }
    }
    
    /// The path selected by the path processor
    @Published private(set) var pathProcessorChosenPath: SCIONPath? {
        didSet {
            if oldValue != pathProcessorChosenPath {
                print("Connection switched from path \(oldValue?.canonicalFingerprintShortWithTCInfo ?? "-") to \(pathProcessorChosenPath?.canonicalFingerprintShortWithTCInfo ?? "-")")
            }
            updateEffectivePath()
        }
    }
    
    /// Custom selected path. Overrides the selection of the path processor
    @Published var fixedPath: SCIONPath? {
        didSet {
            fixedPathSource = fixedPath.map({ SCIONPathSource(path: $0) })
            updateEffectivePath()
        }
    }
    
    private var fixedPathSource: SCIONPathSource?
    
    /// Effective path used. A fixed path has priority. If a mirror path processor is used then the current mirror path is returned. Otherwise the `pathProcessorChosenPath` is returned.
    @Published private(set) var effectivePath: SCIONPath?
    
    private weak var pathPolicyBridge: SCIONPathPolicy!
    
    func forcePolicyUpdate(context: Int64) {
        PathObserver.pathObserverQueue.async {
            self.conn.updatePolicy(context)
        }
    }
    
    private func configureActivePathProcessor() {
        var repeatBWEBoost: Timer?
        failoverSub = fullPathProcessor.failoverPublisher
            .handleOutput({ _ in
                print("FAILOVER DONE")
                repeatBWEBoost?.invalidate()
                NotificationCenter.default.post(name: NSNotification.Name("FailoverHappened"), object: nil)
                repeatBWEBoost = Timer(timeInterval: 20, repeats: false, block: { _ in
                    NotificationCenter.default.post(name: NSNotification.Name("FailoverHappened"), object: nil)
                })
                repeatBWEBoost.map { RunLoop.main.add($0, forMode: .common) }
            })
            .subscribe(failoverPublisher)
        
        activePathProcessorSubscription = fullPathProcessor.orderingChanged
            .sink(receiveValue: { [weak self] failover in
                self?.forcePolicyUpdate(context: failover)
            })
        fullPathProcessor.connect(to: self)
        
        forcePolicyUpdate(context: 0)
    }
    
    var pathProcessor: PathProcessor {
        didSet {
            mirroring = (pathProcessor is MirrorPathSorter) && foreignConnection
            
            // Always join with the path punisher
            fullPathProcessor = pathProcessor.joinFlatStateful(with: pathDownPunisher)
            pathPolicyBridge.processor = fullPathProcessor

            configureActivePathProcessor()
            
            updateEffectivePath()
        }
    }
}

extension NSArray: IosPathCollectionSourceProtocol {
    public func getPathAt(_ index: Int) -> IosPath? {
        return (self[index] as? SCIONPath)?.appnetPath
    }
    
    public func getPathCount() -> Int {
        return count
    }
}

private var pathTranslationCache: [String: SCIONPath] = [:]
private let pathTranslationLock = NSLock()

extension IosPath {
    var tryWrap: SCIONPath? {
        pathTranslationLock.lock()
        defer { pathTranslationLock.unlock() }
        
        return pathTranslationCache[getFingerprint()]
    }
    
    var wrapped: SCIONPath {
        pathTranslationLock.lock()
        defer { pathTranslationLock.unlock() }
        
        // Use the cached path if it exists and if it has the same metadata information as sekf. Skip the cache if the cached path has no metadata but self does
        if let cached = pathTranslationCache[getFingerprint()], (getMetadata() == nil || cached.metadata != nil) {
            return cached
        }
        else {
            let translated = SCIONPath(appnetPath: self)
            pathTranslationCache[getFingerprint()] = translated
            return translated
        }
    }
}

extension IosPathCollectionSourceProtocol {
    var wrapped: [SCIONPath] {
        if getPathCount() == 0 {
            return []
        }
        
        let flattened = (0..<getPathCount()).compactMap({ getPathAt($0) })
        let translated = flattened.map({ path -> SCIONPath in
            return path.wrapped
        })
        
        return translated
    }
}

/// Bridging object that conforms to the Go interface IosPathPolicyFilterProtocol and is used as a path policy in PAN.
final class SCIONPathPolicy: NSObject, IosPathPolicyFilterProtocol {
    fileprivate(set) weak var processor: (PathProcessor & AnyObject)?
    
    init(processor: (PathProcessor & AnyObject)? = nil) {
        self.processor = processor
    }
    
    func sort(_ paths: IosPathCollectionSourceProtocol?, context: Int64) -> IosPathCollectionSourceProtocol? {
        guard let processor = processor else { return paths }
        let translated = paths?.wrapped ?? []
        let filtered = processor.process(translated, context: context)
        return filtered as NSArray
    }
}

// MARK: - Client

final class SCIONClient {
    let appnetConnection: IosConnection
    let readBuffer: NSMutableData
    
    let remoteAddress: SCIONAddress
    
    private var pullSubject: PassthroughSubject<SCIONMessage, Never>?
    
    let queue = DispatchQueue(label: "scion client", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: nil)

    private let pullLock = NSLock()
    
    private(set) var closed = false
    
    /// Client
    fileprivate init(connectingTo remote: String, readBufferSize: Int = 32 * 1024 * 1024, policy: SCIONPathPolicy) throws {
        let address = try SCIONAddress(string: remote)
        var err: NSError? = nil
        guard let buf = NSMutableData(length: readBufferSize),
              let res = IosDialUDP(address.appnetAddress, policy, &err)
        else {
            throw err ?? SCIONError.general
        }
        appnetConnection = res
        if let error = err {
            throw error
        }
        
        readBuffer = buf
        remoteAddress = address
    }
    
    fileprivate func pull() -> AnyPublisher<SCIONMessage, Never> {
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
    
    func close() {
        closed = true
        appnetConnection.close()
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
    
    fileprivate func read() throws -> (Data, SCIONAddress, SCIONPathSource?) {
        let (readBytes, sourceAddress, sourcePath) = try read(into: readBuffer)
        let data = Data(bytes: readBuffer.mutableBytes, count: readBytes)
        return (data, sourceAddress, sourcePath)
    }
}

extension SCIONClient: Identifiable, Equatable, Hashable {
    static func == (lhs: SCIONClient, rhs: SCIONClient) -> Bool {
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
