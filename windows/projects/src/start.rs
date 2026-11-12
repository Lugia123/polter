//! Where a pane of a restored page starts.
//!
//! A pane's record says its directory (`SavedLeaf::cwd`). A record that says
//! nothing -- an old project file, or a save taken before its shell had
//! reported where it was -- used to be left for the core's default, which is
//! the directory the host process happens to be in. That is an accident of
//! how the app was started, not something the project says (task 2042; the
//! macOS half is `ProjectNode.startDirectory` in
//! `ProjectDocument.swift`).
//!
//! **The answer is always from the project's own data**, and the same chain
//! on both hosts: the pane's own directory, and when it names none, the
//! first directory any pane of its page names -- in the order the file
//! writes the panes, left before right, a stack's members in their order
//! (`polter_projectfile::leaves`) -- and a page that names none takes the
//! directory the project's own file is in.
//!
//! The host rewrites the page once, before the layout pipeline sees it, so
//! every consumer of `cwd` (`project::to_layout_shape`, the seed pane in
//! `project_ui::open_page_in_new_tab`) gets the same answer without any of
//! them repeating the rule.

use std::path::Path;

use polter_projectfile::{leaves, leaves_mut, SavedNode};

/// The first directory this page names: a pane's saved `cwd`, in the order
/// the file writes the panes. `None` when no pane here has one.
fn first_cwd(page: &SavedNode) -> Option<&str> {
    leaves(page).into_iter().map(|leaf| leaf.cwd.as_str()).find(|cwd| !cwd.is_empty())
}

/// The page as a saved project's loader hands it to the layout pipeline:
/// every pane whose record names no directory of its own is given one the
/// project names.
///
/// `project_file` is the file the page was read from -- a project is saved
/// as a file beside its snapshots, so the directory that file is in is the
/// project's own directory when the panes say nothing at all.
///
/// **Never the process's directory**: `cwd` is empty in the answer only for
/// a file path with no directory at all, which is the one case where there
/// is nothing to say.
pub fn page_with_start_directories(page: &SavedNode, project_file: &Path) -> SavedNode {
    let start = first_cwd(page)
        .map(str::to_string)
        .or_else(|| project_file.parent().map(|dir| dir.to_string_lossy().into_owned()))
        .unwrap_or_default();
    let mut page = page.clone();
    for leaf in leaves_mut(&mut page) {
        if leaf.cwd.is_empty() {
            leaf.cwd = start.clone();
        }
    }
    page
}
