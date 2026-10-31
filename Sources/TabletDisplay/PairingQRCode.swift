import AppKit
import CoreImage
import Foundation

enum PairingQRCode {
    static func url(host: String, port: UInt16, token: String, udpPort: UInt16) -> URL? {
        var components = URLComponents()
        components.scheme = "tabletdisplay"
        components.host = "pair"
        var items = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token)
        ]
        if udpPort > 0 {
            items.append(URLQueryItem(name: "udpPort", value: String(udpPort)))
        }
        components.queryItems = items
        return components.url
    }

    static func image(for string: String, scale: CGFloat = 8) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
