import Foundation
import Darwin

// Answer only A/AAAA questions for the lease's proxy host, from the daemon's
// validated address list. No DNS query is sent onto the physical network.
enum ProxyDNS {
    static func answer(_ data: Data, host: String, addresses: [String]) -> Data? {
        let q = Array(data)
        guard q.count >= 17, q.count <= 4096, q[2] & 0xf8 == 0,
              q[4] == 0, q[5] == 1 else { return nil }
        var offset = 12
        var labels: [String] = []
        while offset < q.count, q[offset] != 0 {
            let count = Int(q[offset]); offset += 1
            guard count <= 63, offset + count < q.count,
                  let label = String(bytes: q[offset..<(offset + count)], encoding: .ascii)
            else { return nil }
            labels.append(label); offset += count
            guard offset <= 266 else { return nil }
        }
        guard offset + 5 <= q.count else { return nil }
        offset += 1
        let type = Int(q[offset]) * 256 + Int(q[offset + 1])
        guard q[offset + 2] == 0, q[offset + 3] == 1 else { return nil }
        let name = labels.joined(separator: ".").lowercased()
        let allowed = name == host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let family = type == 1 ? AF_INET : AF_INET6
        var records: [[UInt8]] = []
        if allowed && (type == 1 || type == 28) {
            for address in addresses.prefix(16) {
                var bytes = [UInt8](repeating: 0, count: type == 1 ? 4 : 16)
                let parsed = bytes.withUnsafeMutableBytes { buffer in
                    inet_pton(family, address, buffer.baseAddress!)
                }
                if parsed == 1 { records.append(bytes) }
            }
        }
        var response = Array(q[0..<2]) + [0x81, UInt8(allowed ? 0x80 : 0x83),
            0, 1, 0, UInt8(records.count), 0, 0, 0, 0]
        response += q[12..<(offset + 4)]
        for record in records {
            response += [0xc0, 0x0c, UInt8(type >> 8), UInt8(type & 255),
                         0, 1, 0, 0, 0, 5, 0, UInt8(record.count)]
            response += record
        }
        return Data(response)
    }
}
