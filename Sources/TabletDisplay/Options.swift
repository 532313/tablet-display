import Darwin
import Foundation

struct Options {
    var width: Int?
    var widthExplicit = false
    var height: Int?
    var heightExplicit = false
    var port: UInt16 = 9137
    var serial: String?
    var noADB = false
    var duration: Double?
    var bitrateMbps = 20
    var bitrateExplicit = false
    var fps = 60
    var fpsExplicit = false
    var directHost: String?
    var token: String?
    var hidpi: Bool?
    var audio = false
    var audioExplicit = false

    static func parse(_ args: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--width", "--height", "--port", "--serial", "--duration", "--bitrate", "--fps", "--direct-host", "--token":
                index += 1
                guard index < args.count else { throw CLIError.invalid("\(arg) 缺少参数") }
                let value = args[index]
                switch arg {
                case "--width":
                    options.width = try integer(value, option: arg, range: 640...4096)
                    options.widthExplicit = true
                case "--height":
                    options.height = try integer(value, option: arg, range: 480...4096)
                    options.heightExplicit = true
                case "--port":
                    let parsed = try integer(value, option: arg, range: 1...65535)
                    guard let port = UInt16(exactly: parsed) else {
                        throw CLIError.invalid("--port 必须在 1...65535 之间")
                    }
                    options.port = port
                case "--serial":
                    guard !value.isEmpty else { throw CLIError.invalid("--serial 不能为空") }
                    options.serial = value
                case "--duration":
                    guard let parsed = Double(value), parsed.isFinite, parsed > 0 else {
                        throw CLIError.invalid("--duration 必须是大于 0 的秒数")
                    }
                    options.duration = parsed
                case "--bitrate":
                    options.bitrateMbps = try integer(value, option: arg, range: 5...50)
                    options.bitrateExplicit = true
                case "--fps":
                    options.fps = try integer(value, option: arg, range: 15...60)
                    options.fpsExplicit = true
                case "--direct-host":
                    guard isIPv4(value) else {
                        throw CLIError.invalid("--direct-host 必须是 IPv4 地址，例如 192.168.1.10")
                    }
                    options.directHost = value
                case "--token":
                    guard !value.isEmpty else { throw CLIError.invalid("--token 不能为空") }
                    options.token = value
                default:
                    break
                }
            case "--no-adb":
                options.noADB = true
            case "--audio":
                options.audio = true
                options.audioExplicit = true
            case "--no-audio":
                options.audio = false
                options.audioExplicit = true
            case "--hidpi":
                options.hidpi = true
            case "--no-hidpi":
                options.hidpi = false
            case "--help", "-h":
                print("用法: TabletDisplay [--width 2560 --height 1600] [--fps 60] [--bitrate 20] [--port 9137] [--serial 设备号] [--direct-host Mac局域网IP] [--token 令牌] [--hidpi|--no-hidpi] [--audio|--no-audio] [--no-adb] [--duration 秒]")
                Foundation.exit(0)
            default:
                throw CLIError.invalid("未知参数 \(arg)")
            }
            index += 1
        }
        if options.noADB && options.directHost != nil {
            throw CLIError.invalid("--no-adb 不能与 --direct-host 同时使用")
        }
        return options
    }

    private static func integer(_ value: String, option: String, range: ClosedRange<Int>) throws -> Int {
        guard let parsed = Int(value) else {
            throw CLIError.invalid("\(option) 需要整数")
        }
        guard range.contains(parsed) else {
            throw CLIError.invalid("\(option) 必须在 \(range.lowerBound)...\(range.upperBound) 之间")
        }
        return parsed
    }

    private static func isIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }
}

enum CLIError: LocalizedError {
    case invalid(String)
    case virtualDisplay
    case screenRecording

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        case .virtualDisplay:
            return "无法创建虚拟显示器。当前 macOS 可能不支持 CGVirtualDisplay 私有接口。"
        case .screenRecording:
            return "需要屏幕录制权限：请在“系统设置 → 隐私与安全性 → 屏幕录制”中添加并勾选 Tablet Display，然后重新打开应用。"
        }
    }
}
