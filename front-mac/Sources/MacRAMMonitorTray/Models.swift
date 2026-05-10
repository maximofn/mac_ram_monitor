import Foundation

// Mirror of crates/mac-ram-monitor-core/src/model.rs. The Rust types are the
// canonical schema (API path /v1/...). If a field is added there, replicate it
// here verbatim or the JSON decode will silently drop data.

struct Snapshot: Codable, Equatable, Sendable {
    let timestamp: String
    let host: String
    let kernel: String?
    let memory: Memory
    let swap: Swap
    let processes: [RAMProcess]
}

struct Memory: Codable, Equatable, Sendable {
    let totalBytes: UInt64
    let freeBytes: UInt64
    let availableBytes: UInt64
    let buffersBytes: UInt64
    let cachedBytes: UInt64
    let usedBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes"
        case freeBytes = "free_bytes"
        case availableBytes = "available_bytes"
        case buffersBytes = "buffers_bytes"
        case cachedBytes = "cached_bytes"
        case usedBytes = "used_bytes"
    }

    var usedPercent: Float {
        guard totalBytes > 0 else { return 0 }
        return (Float(usedBytes) / Float(totalBytes)) * 100.0
    }
}

struct Swap: Codable, Equatable, Sendable {
    let totalBytes: UInt64
    let freeBytes: UInt64
    let usedBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes"
        case freeBytes = "free_bytes"
        case usedBytes = "used_bytes"
    }

    var usedPercent: Float {
        guard totalBytes > 0 else { return 0 }
        return (Float(usedBytes) / Float(totalBytes)) * 100.0
    }
}

struct RAMProcess: Codable, Equatable, Sendable {
    let pid: UInt32
    let name: String
    let rssBytes: UInt64
    let vszBytes: UInt64
    let memoryPercent: Float

    enum CodingKeys: String, CodingKey {
        case pid
        case name
        case rssBytes = "rss_bytes"
        case vszBytes = "vsz_bytes"
        case memoryPercent = "memory_percent"
    }
}
