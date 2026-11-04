//! The host's bounded parse cache (task 2802, W3a).
//!
//! **One budget for the whole host**, not one per group: 200 entries and
//! 4 MiB. The identity is the whole one the feed keeps -- group, the run's
//! generation, the message's opaque anchor and its content version -- so a
//! row from another group, another generation or after an edit never reads
//! another's document.
//!
//! A fallback caches its reason only; the source text belongs to the feed
//! and is never copied here. Every byte kept is counted by one `cost`
//! function (an estimate of the retained strings and containers, published
//! as such), and an entry that would not fit on its own is not cached at
//! all.

use crate::{Document, Reason};

/// Which message a document belongs to.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Key {
    pub group: String,
    pub generation: u64,
    /// The core's opaque identity; never interpreted and never built from
    /// a `seq`.
    pub anchor: String,
    pub content_version: u64,
}

/// What a cached parse is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entry {
    Document(Document),
    /// The reason only: the caller still holds the source.
    PlainFallback(Reason),
}

#[derive(Debug)]
struct Slot {
    key: Key,
    entry: Entry,
    cost: usize,
}

#[derive(Debug)]
pub struct Cache {
    /// Least recently used first.
    slots: Vec<Slot>,
    bytes: usize,
    max_entries: usize,
    max_bytes: usize,
}

impl Default for Cache {
    fn default() -> Self {
        Cache::new()
    }
}

impl Cache {
    /// The host's own bound: 200 entries, 4 MiB.
    pub fn new() -> Cache {
        Cache::with_limits(200, 4 * 1024 * 1024)
    }

    pub fn with_limits(max_entries: usize, max_bytes: usize) -> Cache {
        Cache {
            slots: Vec::new(),
            bytes: 0,
            max_entries,
            max_bytes,
        }
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    /// The bytes this cache counts as held (an estimate, by `cost`).
    pub fn bytes(&self) -> usize {
        self.bytes
    }

    /// The whole identity: a hit moves the entry to the most-recent end.
    pub fn get(&mut self, key: &Key) -> Option<&Entry> {
        let at = self.slots.iter().position(|s| &s.key == key)?;
        let slot = self.slots.remove(at);
        self.slots.push(slot);
        self.slots.last().map(|s| &s.entry)
    }

    /// Keep an entry. **Nothing over the budget is cached**, and an entry
    /// larger than the whole budget is refused rather than evicting
    /// everything for it.
    pub fn insert(&mut self, key: Key, entry: Entry) {
        let cost = cost(&key, &entry);
        if cost > self.max_bytes || self.max_bytes == 0 || self.max_entries == 0 {
            return;
        }
        if let Some(at) = self.slots.iter().position(|s| s.key == key) {
            let old = self.slots.remove(at);
            self.bytes = self.bytes.saturating_sub(old.cost);
        }
        self.slots.push(Slot { key, entry, cost });
        self.bytes += cost;
        while self.slots.len() > self.max_entries || self.bytes > self.max_bytes {
            let oldest = self.slots.remove(0);
            self.bytes = self.bytes.saturating_sub(oldest.cost);
        }
    }

    /// Parse on a miss and keep the answer, **when it fits**. The entry is
    /// returned either way: an entry too large for the budget is not
    /// cached, which is not the same as not parsed.
    pub fn parse_cached(&mut self, key: Key, source: &str) -> Entry {
        if let Some(at) = self.slots.iter().position(|s| s.key == key) {
            let slot = self.slots.remove(at);
            let entry = slot.entry.clone();
            self.slots.push(slot);
            return entry;
        }
        let entry = match crate::parse(source) {
            crate::Parsed::Document(doc) => Entry::Document(doc),
            crate::Parsed::PlainFallback(reason) => Entry::PlainFallback(reason),
        };
        self.insert(key, entry.clone());
        entry
    }
}

/// The one cost function. Counts the key's strings, the document's retained
/// strings and a fixed figure per container so a document of many tiny
/// cells is not counted as free.
pub fn cost(key: &Key, entry: &Entry) -> usize {
    let mut n = key.group.len() + key.anchor.len() + 64;
    match entry {
        Entry::PlainFallback(_) => n + 16,
        Entry::Document(doc) => {
            n += 48;
            for block in &doc.blocks {
                n += 64;
                match block {
                    crate::Block::Paragraph(runs)
                    | crate::Block::Heading { runs, .. }
                    | crate::Block::Quote { runs, .. } => n += runs_cost(runs),
                    crate::Block::ListItem(item) => {
                        n += 48 + runs_cost(&item.runs);
                    }
                    crate::Block::Code { language, text } => {
                        n += text.len() + language.as_ref().map_or(0, |l| l.len());
                    }
                    crate::Block::Table(table) => {
                        n += 64 + table.columns.len() * 8 + table.header.len() * 32;
                        for cell in &table.header {
                            n += runs_cost(cell);
                        }
                        for row in &table.rows {
                            n += 32;
                            for cell in row {
                                n += runs_cost(cell);
                            }
                        }
                    }
                    crate::Block::Rule => n += 8,
                }
            }
            n
        }
    }
}

fn runs_cost(runs: &[crate::Run]) -> usize {
    let mut n = 0;
    for run in runs {
        n += 32 + run.text.len() + run.style.link.as_ref().map_or(0, |l| l.len());
    }
    n
}
