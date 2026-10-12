import Foundation

struct HTTPProxyEndpoint: Equatable {
    let host: String
    let port: Int
    let username: String
    let password: String

    init?(_ text: String) {
        guard text.count <= 4096,
              text.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
              let url = URLComponents(string: text),
              url.scheme?.lowercased() == "http", var host = url.host?.lowercased(),
              let port = url.port, (1...65535).contains(port),
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:")
        guard !host.isEmpty, host.count <= 253,
              host.rangeOfCharacter(from: hostCharacters.inverted) == nil else { return nil }
        let username = url.percentEncodedUser?.removingPercentEncoding
        let password = url.percentEncodedPassword?.removingPercentEncoding
        guard url.percentEncodedUser == nil || !(username ?? "").isEmpty,
              url.percentEncodedPassword == nil || (password != nil && !(username ?? "").isEmpty),
              (username ?? "").count <= 256, (password ?? "").count <= 1024,
              (username ?? "").rangeOfCharacter(from: .controlCharacters) == nil,
              (password ?? "").rangeOfCharacter(from: .controlCharacters) == nil,
              !(username ?? "").contains(":") else { return nil }
        self.host = host; self.port = port
        self.username = username ?? ""; self.password = password ?? ""
    }
}
