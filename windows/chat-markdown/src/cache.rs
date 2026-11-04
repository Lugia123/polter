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

use std::sync::Arc;

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
    /// **Shared**: a hit hands out the same document, never a copy.
    Document(Arc<Document>),
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

    /// Whether this identity is held, without touching the LRU order:
    /// what a demand consults before asking the worker.
    pub fn contains(&self, key: &Key) -> bool {
        self.slots.iter().any(|s| &s.key == key)
    }

    /// The entry if this identity is held, without touching the LRU order.
    pub fn peek(&self, key: &Key) -> Option<&Entry> {
        self.slots.iter().find(|s| &s.key == key).map(|s| &s.entry)
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
            crate::Parsed::Document(doc) => Entry::Document(std::sync::Arc::new(doc)),
            crate::Parsed::PlainFallback(reason) => Entry::PlainFallback(reason),
        };
        self.insert(key, entry.clone());
        entry
    }
}

/// The one cost function. Counts, as a conservative estimate, the actual
/// `size_of` of the retained values plus **the capacity** of every string
/// and `Vec` (a `Vec`'s own descriptor is counted even when it is empty, so
/// a table of empty cells is not counted as free). A shared link is counted
/// where a run references it -- repeated references are counted again, on
/// purpose, because this is a buffer estimate and not an RSS claim.
pub fn cost(key: &Key, entry: &Entry) -> usize {
    let mut n = std::mem::size_of::<Key>()
        + std::mem::size_of::<Entry>()
        + key.group.capacity()
        + key.anchor.capacity();
    match entry {
        Entry::PlainFallback(reason) => n + std::mem::size_of_val(reason),
        Entry::Document(doc) => {
            n += std::mem::size_of::<Document>();
            n += doc.blocks.capacity() * std::mem::size_of::<crate::Block>();
            for block in &doc.blocks {
                n += block_cost(block);
            }
            n
        }
    }
}

fn block_cost(block: &crate::Block) -> usize {
    match block {
        crate::Block::Paragraph(runs)
        | crate::Block::Heading { runs, .. }
        | crate::Block::Quote { runs, .. } => runs_cost(runs),
        crate::Block::ListItem(item) => {
            std::mem::size_of::<crate::ListItem>() + runs_cost(&item.runs)
        }
        crate::Block::Code { language, text } => {
            std::mem::size_of::<Option<String>>()
                + text.capacity()
                + language.as_ref().map_or(0, |l| l.capacity())
        }
        crate::Block::Table(table) => {
            let mut n = std::mem::size_of::<crate::Table>();
            n += table.columns.capacity() * std::mem::size_of::<crate::Align>();
            n += table.header.capacity() * std::mem::size_of::<Vec<crate::Run>>();
            for cell in &table.header {
                n += runs_cost(cell);
            }
            n += table.rows.capacity() * std::mem::size_of::<Vec<Vec<crate::Run>>>();
            for row in &table.rows {
                // Every row's and every cell's descriptor counts, empty or not.
                n += std::mem::size_of::<Vec<Vec<crate::Run>>>();
                n += row.capacity() * std::mem::size_of::<Vec<crate::Run>>();
                for cell in row {
                    n += runs_cost(cell);
                }
            }
            n
        }
        crate::Block::Rule => std::mem::size_of::<crate::Block>(),
    }
}

fn runs_cost(runs: &Vec<crate::Run>) -> usize {
    // The vector itself, then one descriptor per run whatever its text.
    let mut n = std::mem::size_of::<Vec<crate::Run>>()
        + runs.capacity() * std::mem::size_of::<crate::Run>();
    for run in runs {
        n += run.text.capacity();
        if let Some(link) = &run.style.link {
            n += link.len();
        }
    }
    n
}
