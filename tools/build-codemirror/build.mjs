// Builds `plugins/edit-text/page/vendor/codemirror.bundle.js`, which is
// committed rather than built by `zig build` (`polter-artifacts/2145/PLAN.md`
// §2.2). Run it from anywhere:
//
//   npm --prefix tools/build-codemirror install
//   node tools/build-codemirror/build.mjs
//   cp tools/build-codemirror/codemirror.bundle.js plugins/edit-text/page/vendor/
//   shasum -a 256 plugins/edit-text/page/vendor/codemirror.bundle.js \
//     | cut -d' ' -f1 > tools/build-codemirror/BUNDLE.sha256
//
// ⚠️ **Everything is resolved against this file's own directory, not the
// working directory.** esbuild resolves a relative `entryPoints` against the
// process's cwd, so the same line meant two different files depending on
// where somebody stood when they ran it -- and from this directory (the
// obvious place, since `npm --prefix` puts `node_modules` beside it) it meant
// a `src/entry.js` that does not exist. A build script that only works from a
// directory nobody names is a build script that is not reproducible.
import { build } from "esbuild";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

await build({
  absWorkingDir: here,
  entryPoints: [join(here, "entry.js")],
  bundle: true,
  format: "iife",
  globalName: "PolterEditText",
  outfile: join(here, "codemirror.bundle.js"),
  minify: true,
  legalComments: "none",
  target: ["safari15", "chrome100", "edge100"],
});
