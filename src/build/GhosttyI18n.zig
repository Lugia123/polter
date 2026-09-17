const GhosttyI18n = @This();

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("Config.zig");
const gresource = @import("../apprt/gtk/build/gresource.zig");
const locales = @import("../os/i18n_locales.zig").locales;

/// The gettext domain, which **must** be the same string the runtime asks
/// for: `i18n._` calls `dgettext(build_config.bundle_id, …)`, and a catalog
/// installed under any other name is one it will never find. They were two
/// separate literals until a fork changed the id in one of them; see
/// `bundle_id.zig`.
const domain = @import("bundle_id.zig").value;

owner: *std.Build,
steps: []*std.Build.Step,

/// This step updates the translation files on disk that should be
/// committed to the repo.
update_step: *std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyI18n {
    _ = cfg;

    var steps: std.ArrayList(*std.Build.Step) = .empty;
    defer steps.deinit(b.allocator);

    inline for (locales) |locale| {
        // There is no encoding suffix in the LC_MESSAGES path on FreeBSD,
        // so we need to remove it from `locale` to have a correct destination string.
        // (/usr/local/share/locale/en_AU/LC_MESSAGES)
        const target_locale = comptime if (builtin.target.os.tag == .freebsd)
            std.mem.trimEnd(u8, locale, ".UTF-8")
        else
            locale;

        const msgfmt = b.addSystemCommand(&.{ "msgfmt", "-o", "-" });
        msgfmt.addFileArg(b.path("po/" ++ locale ++ ".po"));

        try steps.append(b.allocator, &b.addInstallFile(
            msgfmt.captureStdOut(.{}),
            std.fmt.comptimePrint(
                "share/locale/{s}/LC_MESSAGES/{s}.mo",
                .{ target_locale, domain },
            ),
        ).step);
    }

    return .{
        .owner = b,
        .update_step = try createUpdateStep(b),
        .steps = try steps.toOwnedSlice(b.allocator),
    };
}

pub fn install(self: *const GhosttyI18n) void {
    self.addStepDependencies(self.owner.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyI18n,
    other_step: *std.Build.Step,
) void {
    for (self.steps) |step| other_step.dependOn(step);
}

fn createUpdateStep(b: *std.Build) !*std.Build.Step {
    const xgettext = b.addSystemCommand(&.{
        "xgettext",
        "--language=C", // Silence the "unknown extension" errors
        "--from-code=UTF-8",
        "--keyword=_",
        "--keyword=N_",
        "--keyword=C_:1c,2",

        // The conversations window's own wrapper around `_`. Without this
        // its strings are not in the template, and the next `msgmerge`
        // marks every translation of them obsolete -- the strings would
        // still work until somebody updated the translations, and then
        // quietly stop.
        "--keyword=tr",
    });

    // Collect to intermediate .pot file
    xgettext.addArg("-o");
    const gtk_pot = xgettext.addOutputFileArg("gtk.pot");

    // Not cacheable due to the gresource files
    xgettext.has_side_effects = true;

    inline for (gresource.blueprints) |blp| {
        const path = std.fmt.comptimePrint(
            "src/apprt/gtk/ui/{[major]}.{[minor]}/{[name]s}.blp",
            blp,
        );
        // The arguments to xgettext must be the relative path in the build root
        // or the resulting files will contain the absolute path. This will cause
        // a lot of churn because not everyone has the Ghostty code checked out in
        // exactly the same location.
        xgettext.addArg(path);
        // Mark the file as an input so that the Zig build system caching will work.
        xgettext.addFileInput(b.path(path));
    }

    {
        // Iterate over all of the files underneath `src/apprt/gtk`. We store
        // them in an array so that they can be sorted into a determininistic
        // order. That will minimize code churn as directory walking is not
        // guaranteed to happen in any particular order.

        var gtk_files: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (gtk_files.items) |item| b.allocator.free(item);
            gtk_files.deinit(b.allocator);
        }

        var gtk_dir = try b.build_root.handle.openDir(
            b.graph.io,
            "src/apprt/gtk",
            .{ .iterate = true },
        );
        defer gtk_dir.close(b.graph.io);

        var walk = try gtk_dir.walk(b.allocator);
        defer walk.deinit();
        while (try walk.next(b.graph.io)) |src| {
            switch (src.kind) {
                .file => if (!std.mem.endsWith(
                    u8,
                    src.basename,
                    ".zig",
                )) continue,

                else => continue,
            }

            try gtk_files.append(b.allocator, try b.allocator.dupe(u8, src.path));
        }

        std.mem.sort(
            []const u8,
            gtk_files.items,
            {},
            struct {
                fn lt(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.lt,
        );

        for (gtk_files.items) |item| {
            const path = b.pathJoin(&.{ "src/apprt/gtk", item });
            // The arguments to xgettext must be the relative path in the build root
            // or the resulting files will contain the absolute path. This will
            // cause a lot of churn because not everyone has the Ghostty code
            // checked out in exactly the same location.
            xgettext.addArg(path);
            // Mark the file as an input so that the Zig build system caching will work.
            xgettext.addFileInput(b.path(path));
        }
    }

    // For localization of command palette
    const command_palette_path = "src/input/command.zig";
    xgettext.addArg(command_palette_path);
    xgettext.addFileInput(b.path(command_palette_path));

    // The conversations window. It is a CLI action rather than part of an
    // apprt, so the walk over `src/apprt/gtk` above does not reach it --
    // which is why every string in it was a Chinese literal for as long as
    // it existed: there was nowhere for a translation of one to go.
    const chat_path = "src/cli/chat.zig";
    xgettext.addArg(chat_path);
    xgettext.addFileInput(b.path(chat_path));

    // Add support for localizing our `nautilus` integration
    const xgettext_py = b.addSystemCommand(&.{
        "xgettext",
        "--language=Python",
        "--from-code=UTF-8",
    });

    // Collect to intermediate .pot file
    xgettext_py.addArg("-o");
    const py_pot = xgettext_py.addOutputFileArg("py.pot");

    const nautilus_script_path = "dist/linux/ghostty_nautilus.py";
    xgettext_py.addArg(nautilus_script_path);
    xgettext_py.addFileInput(b.path(nautilus_script_path));

    // **The Windows host, in its own language.**
    //
    // It was in neither list above, and the consequence is the one this file
    // records for `src/cli/chat.zig`: a string with nowhere to go is a string
    // nobody translates. The settings page was hardcoded in English and the
    // menu two windows away in Chinese.
    //
    // **Read as Rust, not as C.** It used to go through the C invocation
    // above, and a C lexer reads a Rust lifetime (`&'static str`) as an
    // unterminated character constant: 36 warnings once seven host files
    // carried markers, on a step whose output nobody reads -- which is how a
    // real warning gets missed. A file filter kept the count down by skipping
    // files that did not name `crate::i18n`, and that filter was itself a
    // silent hole: `i18n::tr("…")` written in `main.rs` would never have been
    // extracted. C also misreads three Rust spellings rather than dropping
    // them -- `r#"…"#`, a `\` line continuation and `\u{…}` -- producing a
    // msgid the running host never looks up. Measured on the same files, the
    // Rust lexer gives the same 104 messages with none of that.
    //
    // **So this needs xgettext 0.24 or newer** (Rust support arrived in
    // February 2025). An older one stops the step with "language `Rust'
    // unknown", which is loud; nothing else in the build uses xgettext.
    const xgettext_rs = b.addSystemCommand(&.{
        "xgettext",
        "--language=Rust",
        "--from-code=UTF-8",
        // A `// TRANSLATORS:` comment directly above a call reaches the
        // translator as a `#.` line. Without this the host's notes -- the
        // four spaces that are column padding, what a `{}` counts -- stay in
        // the source, where no translator reads.
        "--add-comments=TRANSLATORS:",
        // `windows/host/src/i18n.rs`'s lookup. The name is load-bearing:
        // rename the function and every string in the host leaves the
        // template without anything going red.
        "--keyword=tr",
        // The marker for a string that has to sit in a `const` -- a table
        // cannot call a function, so it is marked where it is written and
        // looked up where it is used. `n_` rather than `N_` because Rust
        // warns on a capitalised function name.
        "--keyword=n_",
    });
    xgettext_rs.addArg("-o");
    const host_pot = xgettext_rs.addOutputFileArg("host.pot");
    // Same reason as above: a file added under the walk is an input the
    // cache has not seen.
    xgettext_rs.has_side_effects = true;

    {
        // **Walked rather than named file by file**, and every `.rs` file:
        // naming files is what put `chat.zig` in here as a special case, and
        // a marker filter is what the note above describes going wrong.
        // Sorted so the template does not churn with directory order.
        var host_files: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (host_files.items) |item| b.allocator.free(item);
            host_files.deinit(b.allocator);
        }

        var host_dir = try b.build_root.handle.openDir(
            b.graph.io,
            "windows/host/src",
            .{ .iterate = true },
        );
        defer host_dir.close(b.graph.io);

        var walk = try host_dir.walk(b.allocator);
        defer walk.deinit();
        while (try walk.next(b.graph.io)) |src| {
            switch (src.kind) {
                .file => if (!std.mem.endsWith(u8, src.basename, ".rs")) continue,
                else => continue,
            }
            try host_files.append(b.allocator, try b.allocator.dupe(u8, src.path));
        }

        std.mem.sort(
            []const u8,
            host_files.items,
            {},
            struct {
                fn lt(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.lt,
        );

        for (host_files.items) |item| {
            const path = b.pathJoin(&.{ "windows/host/src", item });
            xgettext_rs.addArg(path);
            xgettext_rs.addFileInput(b.path(path));
        }
    }

    // Merge pot files
    const xgettext_merge = b.addSystemCommand(&.{
        "xgettext",
        "--add-comments=Translators",
        "--package-name=" ++ domain,
        "--msgid-bugs-address=m@mitchellh.com",
        "--copyright-holder=\"Mitchell Hashimoto, Ghostty contributors\"",
        "-o",
        "-",
    });
    // py_pot needs to be first on merge order because of `xgettext` behavior around
    // charset when merging the two `.pot` files
    xgettext_merge.addFileArg(py_pot);
    xgettext_merge.addFileArg(gtk_pot);
    xgettext_merge.addFileArg(host_pot);
    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(
        xgettext_merge.captureStdOut(.{}),
        "po/" ++ domain ++ ".pot",
    );

    inline for (locales) |locale| {
        const msgmerge = b.addSystemCommand(&.{ "msgmerge", "--quiet", "--no-fuzzy-matching" });
        msgmerge.addFileArg(b.path("po/" ++ locale ++ ".po"));
        msgmerge.addFileArg(xgettext_merge.captureStdOut(.{}));
        usf.addCopyFileToSource(msgmerge.captureStdOut(.{}), "po/" ++ locale ++ ".po");
    }

    return &usf.step;
}
