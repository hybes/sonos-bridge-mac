import Foundation
import Darwin

final class SonosClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    func discover(cachedHosts: [String]) async throws -> [Room] {
        for host in Array(Set(cachedHosts)).prefix(4) {
            if let base = Room.baseURL(host: host), let rooms = try? await topology(at: base) { return rooms }
        }
        let locations = await Task.detached(priority: .utility) { Self.discoverLocations() }.value
        for location in locations {
            if let base = Room.baseURL(location: location), let rooms = try? await topology(at: base) { return rooms }
        }
        throw BridgeError.noSpeakers
    }

    func topology(at base: URL) async throws -> [Room] {
        let response = try await soap(at: base, service: "ZoneGroupTopology", path: "/ZoneGroupTopology/Control", action: "GetZoneGroupState", arguments: "")
        return try Room.parseTopology(response.value("ZoneGroupState"))
    }

    func playback(in room: Room) async throws -> Playback {
        async let position = transport(at: room.coordinator, action: "GetPositionInfo")
        async let state = transport(at: room.coordinator, action: "GetTransportInfo")
        async let actions = transport(at: room.coordinator, action: "GetCurrentTransportActions")
        return try await Playback(position: position, transport: state, actions: actions, baseURL: room.coordinator)
    }

    func command(_ action: String, in room: Room, position: Double? = nil) async throws {
        guard ["Play", "Pause", "Stop", "Next", "Previous", "Seek"].contains(action) else {
            throw BridgeError.requestFailed("This playback command is unavailable.")
        }
        var extra = action == "Play" ? "<Speed>1</Speed>" : ""
        if action == "Seek" {
            guard let position, position.isFinite, position >= 0, position < 360_000 else {
                throw BridgeError.requestFailed("That playback position is unavailable.")
            }
            let seconds = Int(position)
            let time = String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            extra = "<Unit>REL_TIME</Unit><Target>\(time)</Target>"
        }
        _ = try await transport(at: room.coordinator, action: action, extra: extra)
    }

    func artwork(at url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.mimeType?.hasPrefix("image/") == true, data.count <= 4 * 1_024 * 1_024 else {
            throw BridgeError.requestFailed("Artwork is unavailable.")
        }
        return data
    }

    private func transport(at base: URL, action: String, extra: String = "") async throws -> Element {
        try await soap(at: base, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control", action: action, arguments: "<InstanceID>0</InstanceID>" + extra)
    }

    private func soap(at base: URL, service: String, path: String, action: String, arguments: String) async throws -> Element {
        let urn = "urn:schemas-upnp-org:service:\(service):1"
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(urn)\">\(arguments)</u:\(action)></s:Body></s:Envelope>".utf8)
        let (data, response) = try await session.data(for: request)
        let xml = try Element.parse(data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), xml.first("Fault") == nil else {
            let code = xml.value("errorCode")
            throw BridgeError.requestFailed("Sonos couldn't complete \(action)\(code.isEmpty ? "." : " (\(code)).")")
        }
        return xml
    }

    private static func discoverLocations() -> [String] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &target.sin_addr)
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
        func sendSearch() {
            message.withCString { bytes in
                withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(descriptor, bytes, message.utf8.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        sendSearch()
        // Search physical LAN interfaces too when a VPN owns the default route.
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0 {
            defer { freeifaddrs(interfaces) }
            var pointer = interfaces
            while let current = pointer {
                let interface = current.pointee
                if let address = interface.ifa_addr, address.pointee.sa_family == AF_INET,
                   interface.ifa_flags & UInt32(IFF_UP) != 0,
                   interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                   String(cString: interface.ifa_name).hasPrefix("en") {
                    var local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    if setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_IF, &local, socklen_t(MemoryLayout<in_addr>.size)) == 0 { sendSearch() }
                }
                pointer = interface.ifa_next
            }
        }
        let deadline = Date().addingTimeInterval(2.5)
        var locations = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while Date() < deadline, locations.count < 32 {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                break
            }
            for line in String(decoding: buffer.prefix(count), as: UTF8.self).components(separatedBy: "\r\n") {
                if line.lowercased().hasPrefix("location:") {
                    let location = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if Room.baseURL(location: location) != nil { locations.insert(location) }
                }
            }
        }
        return locations.sorted()
    }
}
