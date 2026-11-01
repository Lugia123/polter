// The one entry file `tools/build-codemirror` bundles into the product the
// `edit-text` plugin ships (`plugins/edit-text/page/vendor/codemirror.bundle.js`).
//
// **This file is not shipped; the bundle it produces is.** Nothing in Polter's
// build compiles JavaScript (`PLAN.md` §2.2, `dev-docs/poltergeist/plugins.md`
// §四), so what the plugin loads is this file's output, committed beside the
// LICENSE. Rebuilding it is a person's step, run when CodeMirror is upgraded,
// and never part of `zig build`.
//
// What it exposes is deliberately small: an editor with the extensions the
// plugin's page actually uses, and a change listener. A page that wanted more
// would import CodeMirror itself and get a second copy of it.

import { EditorState } from "@codemirror/state";
import {
  EditorView,
  lineNumbers,
  highlightActiveLine,
  drawSelection,
  keymap,
} from "@codemirror/view";
import { history, historyKeymap, defaultKeymap, indentWithTab } from "@codemirror/commands";
import { syntaxHighlighting, HighlightStyle, bracketMatching, foldGutter } from "@codemirror/language";
import { tags } from "@lezer/highlight";

/// The colours, aligned with the host's own token names rather than picked
/// here -- a preview that coloured a comment differently from the window
/// around it would be a second palette. The host hands the real values to the
/// page over the bridge (`look`), and this is only what a page shows before
/// the first answer arrives.
const highlight = HighlightStyle.define([
  { tag: tags.keyword, color: "#c678dd" },
  { tag: [tags.string, tags.special(tags.string)], color: "#98c379" },
  { tag: [tags.number, tags.bool, tags.null], color: "#d19a66" },
  { tag: tags.comment, color: "#7f848e", fontStyle: "italic" },
  { tag: [tags.typeName, tags.className], color: "#e5c07b" },
  { tag: tags.propertyName, color: "#61afef" },
  { tag: tags.heading, color: "#e06c75", fontWeight: "600" },
  { tag: tags.link, color: "#61afef", textDecoration: "underline" },
]);

/// CodeMirror 6, arranged the way the plugin's page uses it.
///
/// `onChange` is called with the whole document after every change, which
/// includes the commit a composition ends with: a page that wanted only the
/// committed text should compare against `view.composing` rather than keep a
/// second copy of the composition rules.
export function makeEditor(parent, text, readOnly, onChange) {
  return new EditorView({
    state: EditorState.create({
      doc: text || "",
      extensions: [
        lineNumbers(),
        foldGutter(),
        history(),
        drawSelection(),
        highlightActiveLine(),
        bracketMatching(),
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
        syntaxHighlighting(highlight),
        EditorState.readOnly.of(!!readOnly),
        EditorView.theme({
          "&": { height: "100%" },
          ".cm-scroller": { overflow: "auto" },
        }),
        EditorView.updateListener.of((update) => {
          if (!update.docChanged || !onChange) return;
          onChange(update.state.doc.toString());
        }),
      ],
    }),
    parent,
  });
}

export { EditorView, EditorState };
