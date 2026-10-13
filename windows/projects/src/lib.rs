//! A project while the host has it in hand.
//!
//! Three things, none of which needs a window:
//!
//!   * `pages` -- which open tab is which page of the file, and what a save
//!     makes of the tabs that are open and the pages that are not.
//!   * `placement` -- where a window of a project opens, given where it was
//!     and which screens are there now.
//!   * `autosave` -- how soon a change is written, and that changes which
//!     never stop arriving do not put the write off for ever.
//!
//! **These are the macOS host's rules, case for case** (`ProjectPages.swift`,
//! `ProjectPlacement`, `ProjectAutosave.swift`), and the tests here are its
//! tests with the same inputs. What a project file says and the bytes it is
//! written as are `polter-projectfile`.

pub mod autosave;
pub mod pages;
pub mod placement;

#[cfg(test)]
mod tests;
