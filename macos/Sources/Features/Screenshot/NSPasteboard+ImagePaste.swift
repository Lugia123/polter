import AppKit

extension NSPasteboard {
    /// The three facts `ImagePaste.source` decides on.
    ///
    /// The image and the files are judged by declared type alone, so a lazy
    /// provider is not asked for an image that is then not used. The text is
    /// read, because a declared string that is empty is not text to paste --
    /// and then the image beside it is what the person copied.
    var ghosttyImagePasteFacts: ImagePaste.Clipboard {
        let types = self.types ?? []
        let text = types.contains(.string) ? (string(forType: .string) ?? "") : ""
        return .init(
            hasText: !text.isEmpty,
            hasFiles: types.contains(.fileURL),
            hasImage: types.contains(.png) || types.contains(.tiff))
    }

    /// The image on the pasteboard as PNG data: the PNG itself when there is
    /// one (a system screenshot), otherwise whatever AppKit can decode,
    /// re-encoded.
    func ghosttyImagePNG() -> Data? {
        if let png = data(forType: .png), !png.isEmpty { return png }
        guard let tiff = data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
