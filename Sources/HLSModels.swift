import Foundation

struct HLSVariant: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let bandwidth: Int
    let resolution: String?
}

struct HLSByteRange: Hashable {
    let length: Int64
    let offset: Int64
}

struct HLSKey: Hashable {
    let method: String
    let url: URL?
    let iv: Data?
    let keyFormat: String
}

struct HLSMap: Hashable {
    let url: URL
    let byteRange: HLSByteRange?
}

struct HLSSegment: Identifiable {
    let id: Int
    let sequence: Int
    let url: URL
    let duration: Double
    let byteRange: HLSByteRange?
    let key: HLSKey?
    let map: HLSMap?
}

struct HLSPlaylist {
    let variants: [HLSVariant]
    let segments: [HLSSegment]
    let mediaSequence: Int
    let isEndList: Bool
}


struct HLSInspection {
    let variants: [HLSVariant]
    let segmentCount: Int
    let duration: Double
    let isEndList: Bool
}
