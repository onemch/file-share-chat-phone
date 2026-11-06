import Foundation
import Darwin

/// 取本机局域网 IPv4 地址（优先 WiFi en0），失败回退 127.0.0.1。
/// 与 Python `get_local_ip()` 目的一致：给其他设备显示的可访问地址。
func localLANIPv4() -> String {
    if let ip = ipFromInterfaces() { return ip }
    if let ip = ipFromUDPProbe() { return ip }
    return "127.0.0.1"
}

private func ipFromInterfaces() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(first) }

    var fallback: String?
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let p = cursor {
        let name = String(cString: p.pointee.ifa_name)
        let flags = Int32(p.pointee.ifa_flags)
        if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
           (flags & IFF_LOOPBACK) == 0 {
            var host = [CChar](repeating: 0, count: 64)
            let len = socklen_t(MemoryLayout<sockaddr_in>.size)
            if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if isPrivateIPv4(ip) {
                    if name == "en0" { return ip }   // WiFi 优先
                    if fallback == nil { fallback = ip }
                }
            }
        }
        cursor = p.pointee.ifa_next
    }
    return fallback
}

private func isPrivateIPv4(_ ip: String) -> Bool {
    if ip.hasPrefix("192.168.") { return true }
    if ip.hasPrefix("10.") { return true }
    if ip.hasPrefix("172.") {
        let parts = ip.split(separator: ".")
        if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
            return true
        }
    }
    return false
}

/// 与 Python 一致：用 UDP connect 到公网地址后读取本地 socket 地址。
private func ipFromUDPProbe() -> String? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(80).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("8.8.8.8"))

    let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else { return nil }

    var local = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &local) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &length)
        }
    }
    guard ok == 0 else { return nil }

    var host = [CChar](repeating: 0, count: 64)
    let ok2 = withUnsafeMutablePointer(to: &local) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host,
                        socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
    }
    guard ok2 == 0 else { return nil }
    let ip = String(cString: host)
    return ip == "0.0.0.0" ? nil : ip
}
