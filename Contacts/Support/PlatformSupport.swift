import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Image {
    /// Builds an `Image` from encoded image data on either platform.
    init?(imageData data: Data) {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #endif
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

/// In-memory cache of contact thumbnails, invalidated whenever the store reloads.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var images: [String: Image] = [:]
    private var misses: Set<String> = []

    func cachedImage(for id: String) -> Image? { images[id] }

    func image(for id: String) async -> Image? {
        if let cached = images[id] { return cached }
        if misses.contains(id) { return nil }
        guard let data = await ContactsRepository.shared.thumbnailData(for: id),
              let image = Image(imageData: data) else {
            misses.insert(id)
            return nil
        }
        images[id] = image
        return image
    }

    func removeAll() {
        images.removeAll()
        misses.removeAll()
    }
}

nonisolated enum ImageDownscaler {
    /// Re-encodes an image as JPEG no larger than `maxPixelSize` on its longest side,
    /// so photos from the library don't bloat the address book.
    static func jpegData(from data: Data, maxPixelSize: Int = 1024) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// URLs that hand off to the system's communication and maps apps.
nonisolated enum ContactActionURL {
    static func call(_ number: String) -> URL? { URL(string: "tel:\(number.dialable)") }
    static func message(_ handle: String) -> URL? { URL(string: "sms:\(handle.contains("@") ? handle : handle.dialable)") }
    static func faceTime(_ handle: String) -> URL? { URL(string: "facetime:\(handle.contains("@") ? handle : handle.dialable)") }
    static func faceTimeAudio(_ handle: String) -> URL? { URL(string: "facetime-audio:\(handle.contains("@") ? handle : handle.dialable)") }
    static func email(_ address: String) -> URL? {
        URL(string: "mailto:\(address.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? address)")
    }

    static func web(_ string: String) -> URL? {
        let trimmed = string.trimmed
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }

    static func maps(_ address: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "address", value: address)]
        return components?.url
    }
}

nonisolated extension String {
    /// Phone number reduced to characters a dialer understands.
    var dialable: String {
        String(filter { $0.isNumber || "+*#,;".contains($0) })
    }
}

/// A `.vcf` document for `fileExporter`.
struct VCardDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.vCard]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Lazily serializes contacts as vCard for `ShareLink` and drag-and-drop.
struct ContactsVCard: Transferable {
    var ids: [String]
    var filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .vCard) { card in
            try await ContactsRepository.shared.vCardData(for: card.ids)
        }
        .suggestedFileName { $0.filename + ".vcf" }
    }
}
