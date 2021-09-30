//
//  WebRTCStats.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 21.04.21.
//

import Foundation

enum RTPKind: String, Decodable {
    case audio
    case video
}

// type: remote-inbound-rtp
struct RemoteInboundRTPStats: Decodable {
    let ssrc: Int
    let roundTripTimeMeasurements: Int
    let localId: String
    let fractionLost: Double
    let roundTripTime: Double
    let codecId: String
    let transportId: String
    let packetsLost: Int
    let kind: RTPKind
    let totalRoundTripTime: Double
    let jitter: Double
}

// type: track where id contains receiver and kind == audio
struct TrackReceiverAudioRTCStats: Decodable {
    let totalAudioEnergy: Double
    let totalSamplesReceived: Int
    let audioLevel: Double?
    let jitterBufferFlushes: Int
    let delayedPacketOutageSamples: Int
    let relativePacketArrivalDelay: Double
    let insertedSamplesForDeceleration: Int
    let totalSamplesDuration: Double
    let totalInterruptionDuration: Double
    let ended: Bool
    let remoteSource: Bool
    let concealedSamples: Int
    let kind: RTPKind
    let removedSamplesForAcceleration: Int
    let silentConcealedSamples: Int
    let jitterBufferEmittedCount: Int
    let concealmentEvents: Int
    let trackIdentifier: String
    let jitterBufferTargetDelay: Double
    let detached: Bool
    let jitterBufferDelay: Double
    let interruptionCount: Int
}

// type: track where id contains receiver and kind == video
struct TrackReceiverVideoRTCStats: Decodable {
    let framesReceived: Int
    let ended: Bool
    let framesDecoded: Int
    let trackIdentifier: String
    let freezeCount: Int
    let pauseCount: Int
    let totalFreezesDuration: Double
    let remoteSource: Bool
    let frameWidth: Int?
    let jitterBufferDelay: Double
    let sumOfSquaredFramesDuration: Double
    let totalPausesDuration: Double
    let frameHeight: Int?
    let kind: RTPKind
    let detached: Bool
    let totalFramesDuration: Double
    let jitterBufferEmittedCount: Int
    let framesDropped: Int
}

// type: track where id contains sender and kind == audio
struct TrackSenderAudioRTCStats: Decodable {
    let echoReturnLossEnhancement: Double?
    let mediaSourceId: String?
    let echoReturnLoss: Double?
    let remoteSource: Bool
    let kind: RTPKind
    let ended: Bool
    let trackIdentifier: String
    let detached: Bool
}

// type: track where id contains sender and kind == video
struct TrackSenderVideoRTCStats: Decodable {
    let mediaSourceId: String?
    let trackIdentifier: String
    let detached: Bool
    let kind: RTPKind
    let hugeFramesSent: Int
    let frameWidth: Int
    let remoteSource: Bool
    let framesSent: Int
    let frameHeight: Int
    let ended: Bool
}

// type: transport
struct TransportWebRTCStats: Decodable {
    let dtlsCipher: String?
    let bytesSent: Int
    let packetsReceived: Int
    let selectedCandidatePairId: String?
    let tlsVersion: String?
    let localCertificateId: String
    let bytesReceived: Int
    let packetsSent: Int
    let dtlsState: String
    let srtpCipher: String?
    let remoteCertificateId: String?
    let selectedCandidatePairChanges: Int
}

// type: outbound-rtp where kind == video
struct VideoOutboundRTPStats: Decodable {
    let encoderImplementation: String?
    let packetsSent: Int
    let trackId: String
    let remoteId: String?
    let totalEncodeTime: Double
    let bytesSent: Int
    let retransmittedBytesSent: Int
    let mediaType: String
    let pliCount: Int
//    let sliCount: Int
    let retransmittedPacketsSent: Int
    let totalEncodedBytesTarget: Int
    let firCount: Int
    let kind: RTPKind
    let framesEncoded: Int
    let qualityLimitationResolutionChanges: Int
    let framesSent: Int
    let framesPerSecond: Int?
    let qualityLimitationReason: String
    let headerBytesSent: Int
    let keyFramesEncoded: Int
    let ssrc: Int
    let transportId: String
    let frameWidth: Int?
    let hugeFramesSent: Int
    let totalPacketSendDelay: Double
    let codecId: String?
    let nackCount: Int
    let frameHeight: Int?
    let mediaSourceId: String?
    let qpSum: Int?
}

// type: outbound-rtp where kind == audio
struct AudioOutboundRTPStats: Decodable {
    let kind: RTPKind
    let transportId: String
    let mediaType: String
    let bytesSent: Int
    let headerBytesSent: Int
    let ssrc: Int
    let codecId: String?
    let trackId: String
    let retransmittedBytesSent: Int
    let retransmittedPacketsSent: Int
    let remoteId: String?
    let mediaSourceId: String?
    let packetsSent: Int
}

struct VideoInbountRTPStats: Decodable {
    let decoderImplementation: String?
    let jitter: Double
    let framesDropped: Int
    let transportId: String
    let lastPacketReceivedTimestamp: TimeInterval?
    let bytesReceived: Int
    let ssrc: Int
    let pliCount: Int
    let headerBytesReceived: Int
    let totalDecodeTime: TimeInterval
    let nackCount: Int
    let codecId: String?
    let firCount: Int
    let framesReceived: Int
    let framesPerSecond: Int?
    let kind: RTPKind
    let trackId: String?
    let frameHeight: Int?
    let frameWidth: Int?
    let totalInterFrameDelay: TimeInterval
    let totalSquaredInterFrameDelay: TimeInterval
    let mediaType: String
    let framesDecoded: Int
    let estimatedPlayoutTimestamp: TimeInterval?
    let keyFramesDecoded: Int
    let packetsLost: Int
    let packetsReceived: Int
}
