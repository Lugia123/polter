import AppKit

// Stand-ins for `tools/mac-logic-tests`. NOT part of the app: this file is
// only ever compiled into the throwaway package that script builds.
//
// The app's `Ghostty` namespace is declared in `GhosttyPackageMeta.swift`,
// which imports the core; the files the package takes only need the name.
//
// `SurfaceView` is here so that code which is generic over "a pane's view"
// and happens to spell the real one in a signature still compiles. It is a
// view with nothing in it. **No test may be about this type**: a test that
// needs a terminal's view to do anything is one the list leaves out.

enum Ghostty {
    final class SurfaceView: NSView, Codable, Identifiable {
        let id: UUID

        init() {
            id = UUID()
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("a stand-in is never decoded from a nib") }

        enum CodingKeys: CodingKey { case id }

        required init(from decoder: Decoder) throws {
            id = try decoder.container(keyedBy: CodingKeys.self).decode(UUID.self, forKey: .id)
            super.init(frame: .zero)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
        }
    }
}
