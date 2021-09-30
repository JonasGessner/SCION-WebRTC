//
//  Path.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 10.05.21.
//

import Foundation
import SCIONDarwin
import CryptoKit

fileprivate func asInterfaceString(_ AS: String, _ interface: UInt64) -> String {
    "\(AS);\(interface)"
}

fileprivate func canonicalLink(_ a: String, _ b: String) -> String {
    return [a, b].sorted().joined(separator: ",")
}

/// Used only for test setup. These are the links controllable via tc on the cloud machine, dubbed "hell" links, inspired by the ETH hell AS.
fileprivate let hellLinks: [String: String] = [
    canonicalLink(asInterfaceString("16-ffaa:1:ede", 6), asInterfaceString("16-ffaa:1:f04", 1)) : "Group 0",
    canonicalLink(asInterfaceString("16-ffaa:1:ede", 7), asInterfaceString("16-ffaa:1:f04", 2)) : "Group 1",
    canonicalLink(asInterfaceString("16-ffaa:1:ede", 8), asInterfaceString("16-ffaa:1:f04", 3)) : "Group 2",
    canonicalLink(asInterfaceString("16-ffaa:1:ede", 9), asInterfaceString("16-ffaa:1:f04", 4)) : "Group 3",
    canonicalLink(asInterfaceString("16-ffaa:1:ede", 10), asInterfaceString("16-ffaa:1:f04", 5)) : "Group 4",
]

/// Opaque representation of a SCION path, containing the raw path bytes and metadata
struct SCIONPath: CustomStringConvertible, Identifiable, Equatable, Hashable {
    struct LinkMetadata: CustomStringConvertible, Equatable {
        /// In microseconds
        let latency: UInt32
        /// In kbit/s
        let bandwidth: UInt32
        
        /// Source interface ID
        let fromInterfaceID: UInt64
        /// String representation of the source IA (ISD-AS)
        let fromIA: String
        
        /// Destination interface ID
        let toInterfaceID: UInt64
        /// String representation of the destination IA (ISD-AS)
        let toIA: String
        
        /// In case this is a hell link
        let hellDescription: String?
        
        init(latency: UInt32, bandwidth: UInt32, fromInterfaceID: UInt64, fromIA: String, toInterfaceID: UInt64, toIA: String) {
            self.latency = latency
            self.bandwidth = bandwidth
            self.fromInterfaceID = fromInterfaceID
            self.fromIA = fromIA
            self.toInterfaceID = toInterfaceID
            self.toIA = toIA
            
            let a = asInterfaceString(fromIA, fromInterfaceID)
            let b = asInterfaceString(toIA, toInterfaceID)

            self.canonicalLinkDescription = canonicalLink(a, b)
            
            hellDescription = hellLinks[canonicalLinkDescription]
        }
        
        let canonicalLinkDescription: String
        
        var QoSDescription: String {
            var extraInfo = [String]()
            
            if bandwidth != 0 {
                extraInfo.append("\(bandwidth)kbit/s")
            }
            if latency != 0 {
                if latency > 1000 {
                    extraInfo.append("\(latency / 1000)ms")
                }
                else {
                    extraInfo.append("\(latency)us")
                }
            }
            
            return extraInfo.joined(separator: ", ")
        }
        
        var description: String {
            var s = "[\(fromIA)#\(fromInterfaceID)"
            
            let QoS = QoSDescription
            
            if !QoS.isEmpty {
                s += "("
                s += QoS
                s += ")"
            }
            
            s += " > \(toIA)#\(toInterfaceID)]"
            
            return s
        }
    }
    
    struct Metadata: CustomStringConvertible {
        let linkMetadata: [LinkMetadata]
        let MTU: UInt16
        
        var description: String {
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            
            let pathDescription = ([linkMetadata.first?.fromIA ?? ""] + linkMetadata.map({ link -> String in
                if link.QoSDescription.isEmpty {
                    return "\(link.fromInterfaceID)>\(link.toInterfaceID) \(link.toIA)"
                }
                else {
                    return "\(link.fromInterfaceID)-(\(link.QoSDescription))->\(link.toInterfaceID) \(link.toIA)"
                }
            }))
            .joined(separator: " ")
            
            return "MTU \(MTU)b: \(pathDescription)"
        }
        
        private func getFullPathInfo<T: Numeric>(_ keyPath: KeyPath<LinkMetadata, T>, initial: T, op: (T, T) -> T) -> T {
            // Want full path info. If one link has no value for this information we don't provide any information
            guard !linkMetadata.contains(where: { $0[keyPath: keyPath] == 0 }) else {
                return 0
            }
            
            return linkMetadata.map({ $0[keyPath: keyPath] }).reduce(initial, op)
        }
        
        var fullPathLatency: UInt32 {
            return getFullPathInfo(\.latency, initial: 0, op: +)
        }
        
        var fullPathBandwidth: UInt32 {
            return getFullPathInfo(\.bandwidth, initial: UInt32.max, op: min)
        }
        
        var pathLatency: UInt32 {
            return linkMetadata.map({ $0.latency }).reduce(0, +)
        }
        
        var pathBandwidth: UInt32 {
            return linkMetadata.map({ $0.bandwidth }).filter({ $0 != 0 }).min() ?? 0
        }
        
        var shortDescription: String {
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            
            let count = linkMetadata.count
            
            var s = "MTU \(MTU), hops \(count)"
            if fullPathLatency != 0 {
                s += ", latency (full): \(fullPathLatency / 1000)ms"
            }
            else if pathLatency != 0 {
                s += ", latency (partial): >\(pathLatency / 1000)ms"
            }
            
            if fullPathBandwidth != 0 {
                s += ", bandwidth (full): \(fullPathBandwidth)kbit/s"
            }
            else if pathBandwidth != 0 {
                s += ", bandwidth (partial): >\(pathBandwidth)kbit/s"
            }
            
            return s
        }
        
        func sharedASes(with other: Metadata) -> Set<String> {
            let ids = other.linkMetadata.map({ $0.fromIA }) + other.linkMetadata.map({ $0.toIA })
            return Set(linkMetadata.map({ $0.fromIA }) + linkMetadata.map({ $0.toIA })).intersection(ids)
        }
        
        func sharedLinks(with other: Metadata) -> [LinkMetadata] {
            let ids = other.linkMetadata.map({ $0.canonicalLinkDescription })
            return linkMetadata.filter({ ids.contains($0.canonicalLinkDescription) })
        }
        
        func linkOverlap(with other: Metadata) -> Double {
            return Double(sharedLinks(with: other).count) / min(Double(linkMetadata.count), Double(other.linkMetadata.count))
        }
    }
    
    let appnetPath: IosPath
    
    let expiration: Date
    let metadata: Metadata?
    
    init(appnetPath: IosPath) {
        self.appnetPath = appnetPath
        func short(_ fingerprint: String) -> String {
            String(SHA256.hash(data: fingerprint.data(using: .utf8)!).map({ String(format: "%02x", $0) }).joined().prefix(5))
        }
        
        hops = appnetPath.length()
        fingerprint = appnetPath.getFingerprint()
        fingerprintShort = short(fingerprint)
        
        canonicalFingerprint = min(fingerprint.components(separatedBy: " ").reversed().joined(separator: " "), fingerprint)
        canonicalFingerprintShort = short(canonicalFingerprint)
        
        if let metadata = appnetPath.getMetadata(), appnetPath.length() > 0 {
            let linkMeta = (0..<appnetPath.length() - 1).map { index -> LinkMetadata in
                let latency = metadata.getLatencyAt(index)
                let bandwidth = metadata.getBandwidthAt(index)
                let fromInterfaceID = metadata.getInterfaceID(at: index)
                let toInterfaceID = metadata.getInterfaceID(at: index + 1)
                
                let fromIA = metadata.getInterfaceIA(at: index)
                let toIA = metadata.getInterfaceIA(at: index + 1)
                
                return LinkMetadata(latency: UInt32(latency), bandwidth: UInt32(bandwidth), fromInterfaceID: UInt64(fromInterfaceID), fromIA: fromIA, toInterfaceID: UInt64(toInterfaceID), toIA: toIA)
            }
            
            let meta = Metadata(linkMetadata: linkMeta, MTU: UInt16(metadata.getMTU()))
            
            self.metadata = meta
        }
        else {
            self.metadata = nil
        }
        
        expiration = Date(timeIntervalSince1970: TimeInterval(appnetPath.getExpiry()))
    }
    
    func reversed() throws -> SCIONPath {
        return try appnetPath.reversed().wrapped
    }
    
    let hops: Int
    
    let fingerprint: String
    let fingerprintShort: String
    let canonicalFingerprint: String
    let canonicalFingerprintShort: String
    
    var canonicalFingerprintShortWithTCInfo: String {
        return canonicalFingerprintShort + (tcIdentifier.map({ " (\($0))" }) ?? "")
    }
    
    var reverseFingerprint: String {
        fingerprint.components(separatedBy: " ").reversed().joined(separator: " ")
    }
    
    var tcIdentifier: String? {
        metadata?.linkMetadata.compactMap({ $0.hellDescription }).first
    }
    
    var description: String {
        return ["ID \(canonicalFingerprint)", metadata?.description]
            .compactMap({ $0 })
            .joined(separator: " ")
    }
    
    var shortDescription: String {
        return ["ID \(canonicalFingerprintShort)", metadata?.description]
            .compactMap({ $0 })
            .joined(separator: " ")
    }
    
    static func == (lhs: SCIONPath, rhs: SCIONPath) -> Bool {
        return lhs.fingerprint == rhs.fingerprint
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(fingerprint)
    }
    
    var id: String {
        return fingerprint
    }
}

/// A lazily initialized path
final class SCIONPathSource: Equatable {
    static func == (lhs: SCIONPathSource, rhs: SCIONPathSource) -> Bool {
        return lhs.fingerprint == rhs.fingerprint
    }
    
    let underlying: IosPath
    
    private(set) lazy var fingerprint = underlying.getFingerprint()
    
    private var _path: SCIONPath?
    var path: SCIONPath {
        if let p = _path {
            if p.metadata != nil {
                return p
            }
            else {
                let w = underlying.tryWrap ?? p
                _path = w
                return w
            }
        }
        else {
            let w = underlying.wrapped
            _path = w
            return w
        }
    }
    
    /// Does the unterlying path have metadata but the wrapped path (`path`) has metadata when wrapped? See IosPath.wrapped
    func canRecoverMetadata() -> Bool {
        return _path != nil && _path?.metadata == nil && underlying.tryWrap?.metadata != nil
    }
    
    init(path: SCIONPath) {
        self._path = path
        self.underlying = path.appnetPath
    }
    
    init(underlying: IosPath) {
        self.underlying = underlying
    }
}
