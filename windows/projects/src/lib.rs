//! A project while the host has it in hand.
//!
//! Four things, none of which needs a window:
//!
//!   * `pages` -- which open tab is which page of the file, and what a save
//!     makes of the tabs that are open and the pages that are not.
//!   * `placement` -- where a window of a project opens, given where it was
//!     and which screens are there now.
//!   * `autosave` -- how soon a change is written, and that changes which
//!     never stop arriving do not put the write off for ever.
//!   * `handback` -- what a pane restored from a project hands back to the
//!     core, and why the core's first word on it is not believed.
//!
//! **These are the macOS host's rules, case for case** (`ProjectPages.swift`,
//! `ProjectPlacement`, `ProjectAutosave.swift`), and the tests here are its
//! tests with the same inputs. What a project file says and the bytes it is
//! written as are `polter-projectfile`.

/// Marks a string for the translation template without looking it up: the
/// host translates it where it is shown. `src/build/GhosttyI18n.zig` reads
/// this crate for string literals inside `n_(…)`. The same name and meaning
/// as the host's `i18n::n_`.
pub const fn n_(s: &'static str) -> &'static str {
    s
}

pub mod autosave;
pub mod handback;
pub mod orders;
pub mod page_rules;
pub mod pages;
pub mod placement;
pub mod stated;

#[cfg(test)]
mod tests;
