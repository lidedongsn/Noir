import Foundation
@testable import NoirEngine

/// 测试片源由 scripts/make-test-media.sh 生成
enum TestMedia {
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent() // NoirEngineTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // NoirKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // 仓库根目录
        .appending(path: "TestMedia")

    static func url(_ name: String) -> URL { directory.appending(path: name) }

    static func demuxer(_ name: String) throws -> Demuxer {
        try Demuxer(source: FileByteSource(url: url(name)))
    }
}

extension Demuxer {
    /// 读取指定流的前 n 个包
    func packets(stream index: Int, count: Int) throws -> [Packet] {
        select(streams: [index])
        var result: [Packet] = []
        while result.count < count, let packet = try readPacket() {
            if packet.streamIndex == index { result.append(packet) }
        }
        return result
    }
}
