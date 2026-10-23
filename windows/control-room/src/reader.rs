//! Reading the right side's pages' answers one field at a time (task 2039,
//! API.md §2.0): **a field missing, or of the wrong kind, costs only what it
//! is drawn as** -- that item is left out, and its path is kept in
//! `missing` for the host to write down -- never the page.
//!
//! What is read for a word and is missing reads as the empty string, which
//! nothing draws (`scene::draws`); what has no such neutral value (a dial's
//! fill, a task's glyph) reads as none. The paths are written the same way
//! on both hosts (`machine.text.swap`, `cards[0].dial.big`), so that their
//! lines can be read against each other.

use crate::json::Value;
use crate::level::Level;

#[derive(Debug, Default)]
pub struct Reader {
    /// Every field that was missing or not what it should be, in the order
    /// met.
    pub missing: Vec<String>,
}

pub fn join(path: &str, key: &str) -> String {
    if path.is_empty() { key.to_string() } else { format!("{path}.{key}") }
}

pub fn at(path: &str, i: usize) -> String {
    format!("{path}[{i}]")
}

impl Reader {
    pub fn miss(&mut self, path: String) {
        self.missing.push(path);
    }

    /// The object at `key`; none, and said, when it is missing or not one.
    pub fn obj<'a>(&mut self, v: &'a Value, path: &str, key: &str) -> Option<&'a Value> {
        match v.get(key) {
            Some(o @ Value::Obj(_)) => Some(o),
            _ => {
                self.miss(join(path, key));
                None
            }
        }
    }

    /// The object at `key` when it may be null (§2.0): none for null,
    /// unsaid; none and said when missing or not an object.
    pub fn nullable_obj<'a>(&mut self, v: &'a Value, path: &str, key: &str) -> Option<&'a Value> {
        match v.get(key) {
            Some(Value::Null) => None,
            Some(o @ Value::Obj(_)) => Some(o),
            _ => {
                self.miss(join(path, key));
                None
            }
        }
    }

    /// The words at `key`; "" -- drawn as nothing -- and said when missing
    /// or not words.
    pub fn text(&mut self, v: &Value, path: &str, key: &str) -> String {
        match v.get(key) {
            Some(Value::Str(s)) => s.clone(),
            _ => {
                self.miss(join(path, key));
                String::new()
            }
        }
    }

    /// Words that may be null (§2.0): none for null, unsaid; none and said
    /// when missing -- the core's mistake -- or not words.
    pub fn nullable_text(&mut self, v: &Value, path: &str, key: &str) -> Option<String> {
        match v.get(key) {
            Some(Value::Null) => None,
            Some(Value::Str(s)) => Some(s.clone()),
            _ => {
                self.miss(join(path, key));
                None
            }
        }
    }

    pub fn int(&mut self, v: &Value, path: &str, key: &str) -> Option<u64> {
        match v.get(key) {
            Some(Value::Int(n)) => Some(*n),
            _ => {
                self.miss(join(path, key));
                None
            }
        }
    }

    pub fn nullable_int(&mut self, v: &Value, path: &str, key: &str) -> Option<u64> {
        match v.get(key) {
            Some(Value::Null) => None,
            Some(Value::Int(n)) => Some(*n),
            _ => {
                self.miss(join(path, key));
                None
            }
        }
    }

    pub fn number(&mut self, v: &Value, path: &str, key: &str) -> Option<f64> {
        match v.get(key) {
            Some(Value::Int(n)) => Some(*n as f64),
            Some(Value::Float(f)) => Some(*f),
            _ => {
                self.miss(join(path, key));
                None
            }
        }
    }

    pub fn boolean(&mut self, v: &Value, path: &str, key: &str) -> Option<bool> {
        match v.get(key) {
            Some(Value::Bool(b)) => Some(*b),
            _ => {
                self.miss(join(path, key));
                None
            }
        }
    }

    /// The list at `key`; empty and said when missing or not a list.
    pub fn list<'a>(&mut self, v: &'a Value, path: &str, key: &str) -> &'a [Value] {
        match v.get(key) {
            Some(Value::Arr(items)) => items,
            _ => {
                self.miss(join(path, key));
                &[]
            }
        }
    }

    /// A level named at `key`; none and said when missing, not words, or a
    /// name this build does not know.
    pub fn level(&mut self, v: &Value, path: &str, key: &str) -> Option<Level> {
        match v.get(key) {
            Some(Value::Str(s)) => Level::parse(s).or_else(|| {
                self.miss(join(path, key));
                None
            }),
            _ => {
                self.miss(join(path, key));
                None
            }
        }
    }

    /// A level that may be null (a `tone`, §2.0).
    pub fn nullable_level(&mut self, v: &Value, path: &str, key: &str) -> Option<Level> {
        match v.get(key) {
            Some(Value::Null) => None,
            _ => self.level(v, path, key),
        }
    }
}

/// Every key path in `v`, depth first, as `Reader` writes them: what the
/// tests that take each one away go through.
#[cfg(test)]
pub fn paths(v: &Value, path: &str, out: &mut Vec<String>) {
    match v {
        Value::Obj(fields) => {
            for (k, x) in fields {
                let p = join(path, k);
                out.push(p.clone());
                paths(x, &p, out);
            }
        }
        Value::Arr(items) => {
            for (i, x) in items.iter().enumerate() {
                paths(x, &at(path, i), out);
            }
        }
        _ => {}
    }
}

/// The value at `path`, as `paths` writes them.
#[cfg(test)]
pub fn get_path<'a>(v: &'a Value, path: &str) -> Option<&'a Value> {
    let mut cur = v;
    for part in path.split('.') {
        let (name, index) = match part.find('[') {
            Some(b) => (&part[..b], part[b + 1..part.len() - 1].parse::<usize>().ok()),
            None => (part, None),
        };
        cur = cur.get(name)?;
        if let Some(i) = index {
            match cur {
                Value::Arr(items) => cur = items.get(i)?,
                _ => return None,
            }
        }
    }
    Some(cur)
}

/// `v` with the field at `path` taken away (`None`) or put to `with`.
#[cfg(test)]
pub fn edited(v: &Value, path: &str, with: Option<Value>) -> Value {
    fn walk(v: &mut Value, parts: &[&str], with: &Option<Value>) {
        let Some((first, rest)) = parts.split_first() else { return };
        // `name[3]` or `name`.
        let (name, index) = match first.find('[') {
            Some(b) => (&first[..b], first[b + 1..first.len() - 1].parse::<usize>().ok()),
            None => (*first, None),
        };
        let Value::Obj(fields) = v else { return };
        let Some(pos) = fields.iter().position(|(k, _)| k == name) else { return };
        match index {
            None if rest.is_empty() => match with {
                None => {
                    fields.remove(pos);
                }
                Some(w) => fields[pos].1 = w.clone(),
            },
            None => walk(&mut fields[pos].1, rest, with),
            Some(i) => {
                if let Value::Arr(items) = &mut fields[pos].1 {
                    if let Some(item) = items.get_mut(i) {
                        walk(item, rest, with);
                    }
                }
            }
        }
    }
    let mut out = v.clone();
    // A path's parts: split at the dots outside brackets; "a[1][2]" does not
    // occur in these answers.
    let parts: Vec<&str> = path.split('.').collect();
    walk(&mut out, &parts, &with);
    out
}
