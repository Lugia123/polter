import AppKit
import CoreTransferable
import UniformTypeIdentifiers

/// Conformance to `Transferable` enables drag-and-drop.
extension Ghostty.SurfaceView: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .ghosttySurfaceId) { surface in
            withUnsafeBytes(of: surface.id.uuid) { Data($0) }
        } importing: { data in
            guard data.count == 16 else {
                throw TransferError.invalidData
            }

            let uuid = data.withUnsafeBytes {
                $0.load(as: UUID.self)
            }

            guard let imported = await Self.find(uuid: uuid) else {
                throw TransferError.invalidData
            }

            return imported
        }
    }

    enum TransferError: Error {
        case invalidData
    }

    @MainActor
    static func find(uuid: UUID) -> Self? {
        guard let del = NSApp.delegate as? Ghostty.Delegate else { return nil }
        return del.ghosttySurface(id: uuid) as? Self
    }
}

extension UTType {
    /// A format that encodes the bare UUID only for the surface. This can be used if you have
    /// a way to look up a surface by ID.
    ///
    /// **This identifier and `Ghostty-Info.plist`'s `UTTypeIdentifier` are one
    /// fact in two files, and they must be the same string.** The name declared
    /// here is what `NSItemProvider` registers, and the plist is the only thing
    /// that puts that name in the system's type database; a `UTType` asked for a
    /// name no bundle has declared comes back `nil`, so
    /// `Transferable+Extension.swift`'s `compactMap { UTType($0) }` drops it and
    /// `pasteboardItem()` returns nil. Nothing about that fails to compile, and
    /// the grab handle still appears and still shows a hand -- the drag simply
    /// never starts. That is how the fork's rename lost pane dragging:
    /// `7de0cab17` changed the plist and left this line. The pair is held
    /// together now by `tools/one-uti-for-a-surface.py`.
    static let ghosttySurfaceId = UTType(exportedAs: "com.lugia.polterSurfaceId")
}

extension NSPasteboard.PasteboardType {
    /// Pasteboard type for dragging surface IDs.
    static let ghosttySurfaceId = NSPasteboard.PasteboardType(UTType.ghosttySurfaceId.identifier)
}
