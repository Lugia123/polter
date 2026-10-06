import Foundation

/// What a screenshot's sidecar says about where it was taken, beyond the
/// picture: the git state of the terminal's directory and the previous
/// screenshot of the same window
/// (`dev-docs/poltergeist/screenshot.md`, section 11).
enum ShotContext {
    // MARK: Git

    /// A repository's state as a sidecar writes it.
    struct Git: Equatable {
        /// The commit that is checked out, abbreviated.
        var head: String
        /// Whether a tracked file differs from that commit.
        var dirty: Bool
    }

    /// How many characters of the commit are written.
    static let headLength = 7

    /// The arguments that ask git for both answers at once.
    static func gitArguments(cwd: String) -> [String] {
        ["-C", cwd, "status", "--porcelain=v2", "--branch", "--untracked-files=no"]
    }

    /// Read the answer to `gitArguments`. Nil when it is not an answer, or
    /// when nothing is checked out yet (a repository with no commit).
    ///
    /// The header lines start with `#`; every other line is a tracked file
    /// that differs.
    static func git(fromStatus output: String) -> Git? {
        var head: String?
        var dirty = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# branch.oid ") {
                let oid = line.dropFirst("# branch.oid ".count)
                guard oid.count >= headLength, oid.allSatisfy(\.isHexDigit) else { return nil }
                head = String(oid.prefix(headLength))
            } else if !line.hasPrefix("#") {
                dirty = true
            }
        }
        return head.map { Git(head: $0, dirty: dirty) }
    }

    /// Where git is, among the places it is installed without the system's
    /// stub. `/usr/bin/git` is deliberately not one: on a Mac with no
    /// developer tools it puts up a dialog offering to install them, and a
    /// screenshot must not do that.
    static func gitExecutable(isExecutable: (String) -> Bool) -> String? {
        [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ].first(where: isExecutable)
    }

    /// Ask git about `cwd`, without waiting: the screenshot goes on, and
    /// `completion` is called on the main thread with the answer, or with
    /// nil when there is none within `timeout` -- not a repository, no git,
    /// or git too slow, which are all the same to a sidecar: the key is
    /// left out.
    static func lookUpGit(cwd: String, timeout: TimeInterval = 0.3, completion: @escaping (Git?) -> Void) {
        guard let git = gitExecutable(isExecutable: FileManager.default.isExecutableFile(atPath:)) else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = gitArguments(cwd: cwd)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var answer: Git?
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            do {
                try process.run()
                // Read on another queue: a status longer than the pipe's
                // buffer would otherwise never finish being written.
                var data = Data()
                let read = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    data = pipe.fileHandleForReading.readDataToEndOfFile()
                    read.signal()
                }
                if done.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                } else if process.terminationStatus == 0, read.wait(timeout: .now() + timeout) == .success {
                    answer = self.git(fromStatus: String(data: data, encoding: .utf8) ?? "")
                }
            } catch {
                answer = nil
            }
            DispatchQueue.main.async { completion(answer) }
        }
    }

    // MARK: The previous screenshot

    /// What a sidecar's text says its screenshot was of; nil when it is not
    /// a sidecar this can read.
    static func earlier(fromSidecar text: String) -> ShotSidecar.Earlier? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let image = root["image"] as? String, !image.isEmpty else { return nil }
        let source = root["source"] as? [String: Any]
        return .init(image: image, app: source?["app"] as? String, title: source?["title"] as? String)
    }

    /// The file name of the newest earlier screenshot in `directory` of the
    /// window `app` / `title`.
    static func previous(app: String?, title: String?, before image: String, in directory: URL) -> String? {
        // A window with no name has no previous one; do not read a week of
        // files to find that out.
        guard let app, !app.isEmpty, let title, !title.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let earlier = names
            .filter { $0.hasSuffix(".json") && ShotStore.isOurs($0) }
            .compactMap { name -> ShotSidecar.Earlier? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
                return self.earlier(fromSidecar: String(data: data, encoding: .utf8) ?? "")
            }
        return ShotSidecar.previous(app: app, title: title, before: image, among: earlier)
    }
}
