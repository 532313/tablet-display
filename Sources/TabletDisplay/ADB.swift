import Foundation

enum ADBError: LocalizedError {
    case notFound
    case noDevice
    case multipleDevices
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到 adb。请安装 Android Platform Tools（Homebrew 或 Android SDK），或设置 ADB 环境变量。"
        case .noDevice:
            return "没有找到可用的平板。若无线调试已关闭（例如平板重启），请插一次 USB，程序会自动切换为无线 ADB。"
        case .multipleDevices:
            return "检测到多台 ADB 设备，请用 --serial 指定平板，或只保留一台。"
        case .failed(let message):
            return "ADB 命令失败：\(message)"
        }
    }
}

struct ADBDevice {
    let serial: String
    var isWireless: Bool { ADB.isWireless(serial) }
}

struct ADB {
    let serial: String

    nonisolated(unsafe) static var logger: ((String) -> Void)?
    private static let endpointKey = "lastWirelessEndpoint"

    private static let executablePath: String? = {
        var candidates: [String] = []
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["ADB"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                candidates.append(String(directory) + "/adb")
            }
        }
        if let home = environment["HOME"] {
            candidates.append(home + "/Library/Android/sdk/platform-tools/adb")
        }
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func run(_ arguments: [String]) throws -> String {
        guard let executablePath else { throw ADBError.notFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() }
        catch { throw ADBError.notFound }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if arguments.first == "devices" || arguments.first == "connect" {
            logger?("adb \(arguments.joined(separator: " ")) -> \(text)")
        }
        guard process.terminationStatus == 0 else { throw ADBError.failed(text) }
        return text
    }

    // MARK: - Device discovery

    static func listDevices() throws -> [ADBDevice] {
        let output = try run(["devices"])
        return output.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            return ADBDevice(serial: String(fields[0]))
        }
    }

    static func isWireless(_ serial: String) -> Bool {
        serial.range(of: #"^\d{1,3}(\.\d{1,3}){3}:\d+$"#, options: .regularExpression) != nil
    }

    static func host(fromSerial serial: String) -> String? {
        guard isWireless(serial) else { return nil }
        return serial.split(separator: ":").first.map(String.init)
    }

    /// Prefer an existing wireless transport, then fall back to USB. With a USB
    /// tablet attached, try to switch adbd to TCP and remember the endpoint so
    /// later launches do not need the cable.
    static func connectPreferred(serial requested: String? = nil) throws -> ADB {
        let devices = try listDevices()
        if let requested {
            guard devices.contains(where: { $0.serial == requested }) else { throw ADBError.noDevice }
            if isWireless(requested) { saveEndpoint(requested) }
            return ADB(serial: requested)
        }

        let wireless = devices.filter(\.isWireless)
        if wireless.count == 1 {
            saveEndpoint(wireless[0].serial)
            return ADB(serial: wireless[0].serial)
        }
        if wireless.count > 1 { throw ADBError.multipleDevices }
        guard devices.count <= 1 else { throw ADBError.multipleDevices }

        if let usb = devices.first {
            if let endpoint = try? switchToWireless(usb: usb.serial) {
                saveEndpoint(endpoint)
                return ADB(serial: endpoint)
            }
            return ADB(serial: usb.serial)
        }

        if let saved = savedEndpoint(), let endpoint = try? connectSaved(saved) {
            saveEndpoint(endpoint)
            return ADB(serial: endpoint)
        }
        throw ADBError.noDevice
    }

    static func connected(serial requested: String?) throws -> ADB {
        try connectPreferred(serial: requested)
    }

    // MARK: - Wireless bootstrap

    static func switchToWireless(usb: String) throws -> String {
        let interface = try run(["-s", usb, "shell", "ip", "-4", "addr", "show", "wlan0"])
        guard let ip = parseWirelessIP(interface) else {
            throw ADBError.failed("无法读取平板 Wi-Fi 地址")
        }
        _ = try? run(["-s", usb, "tcpip", "5555"])
        let endpoint = "\(ip):5555"
        for _ in 0..<10 {
            _ = try? run(["connect", endpoint])
            if (try? run(["-s", endpoint, "get-state"])) == "device" {
                return endpoint
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw ADBError.failed("无法通过 Wi-Fi 连接 \(endpoint)")
    }

    static func parseWirelessIP(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains("inet ") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let index = fields.firstIndex(of: "inet"), index + 1 < fields.count else { continue }
            let value = fields[index + 1].split(separator: "/").first.map(String.init) ?? ""
            if value.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
                return value
            }
        }
        return nil
    }

    static func connectSaved(_ endpoint: String) throws -> String {
        _ = try? run(["connect", endpoint])
        guard (try? run(["-s", endpoint, "get-state"])) == "device" else {
            throw ADBError.failed("无法连接 \(endpoint)")
        }
        return endpoint
    }

    static func savedEndpoint() -> String? {
        UserDefaults.standard.string(forKey: endpointKey)
    }

    static func saveEndpoint(_ endpoint: String) {
        UserDefaults.standard.set(endpoint, forKey: endpointKey)
    }

    // MARK: - Commands

    func command(_ args: [String]) throws -> String {
        try Self.run(["-s", serial] + args)
    }

    func screenSize() -> (Int, Int)? {
        // Android's `wm size` can report the unrotated override size. DisplayInfo
        // reports the current logical size after rotation, matching screenshots.
        let displayInfo = try? command(["shell", "dumpsys", "display"])
        let wmOutput = try? command(["shell", "wm", "size"])
        return Self.parseScreenSize(displayInfo: displayInfo, wmOutput: wmOutput)
    }

    /// Returns the panel's physical resolution, in landscape orientation as
    /// reported by Android. `wm size` distinguishes "Physical size" (hardware)
    /// from "Override size" (a logical/DPI override), so prefer the former.
    static func parseScreenSize(displayInfo: String?, wmOutput: String?) -> (Int, Int)? {
        if let wmOutput, let physical = parseWMSize(wmOutput, key: "Physical size:") {
            return physical
        }
        if let displayInfo,
           let line = displayInfo.split(separator: "\n").first(where: { $0.contains("mBaseDisplayInfo=") }),
           let range = line.range(of: #"real (\d+) x (\d+)"#, options: .regularExpression) {
            let numbers = line[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if numbers.count == 2 { return (numbers[0], numbers[1]) }
        }
        // Last resort only. Never prefer an override over hardware size.
        if let wmOutput, let override = parseWMSize(wmOutput, key: "Override size:") {
            return override
        }
        return nil
    }

    static func parseWMSize(_ output: String, key: String) -> (Int, Int)? {
        for line in output.split(separator: "\n") where line.contains(key) {
            guard let value = line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces) else { continue }
            let parts = value.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { return (parts[0], parts[1]) }
        }
        return nil
    }

    func forward(port: UInt16) throws {
        _ = try command(["reverse", "tcp:\(port)", "tcp:\(port)"])
    }

    func installReceiver(at path: String) throws {
        _ = try command(["install", "-r", path])
    }

    func openReceiver(host: String, port: UInt16, token: String) throws {
        _ = try command(["shell", "am", "start", "-S", "-n", "dev.local.tabletdisplay/.MainActivity",
                         "--es", "host", host, "--ei", "port", String(port), "--es", "token", token])
    }

    func removeForward(port: UInt16) {
        _ = try? command(["reverse", "--remove", "tcp:\(port)"])
    }
}
