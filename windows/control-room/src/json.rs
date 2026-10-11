//! Just enough JSON to read the core's snapshot: strict, no dependencies.
//!
//! The crate has none on purpose (see `Cargo.toml`), and what it reads is
//! one document the core writes with one writer. Anything that writer could
//! not have produced is an error here, not a guess.

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    /// A whole number that is not negative: every number the snapshot has.
    Int(u64),
    /// Any other number.
    Float(f64),
    Str(String),
    Arr(Vec<Value>),
    /// In the order written.
    Obj(Vec<(String, Value)>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub at: usize,
    pub what: &'static str,
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Obj(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

pub fn parse(text: &str) -> Result<Value, Error> {
    let mut p = Parser { s: text.as_bytes(), at: 0, depth: 0 };
    p.space();
    let v = p.value()?;
    p.space();
    if p.at != p.s.len() {
        return Err(p.err("something after the document"));
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    at: usize,
    depth: usize,
}

impl Parser<'_> {
    fn err(&self, what: &'static str) -> Error {
        Error { at: self.at, what }
    }

    fn space(&mut self) {
        while let Some(b' ' | b'\n' | b'\r' | b'\t') = self.s.get(self.at) {
            self.at += 1;
        }
    }

    fn eat(&mut self, word: &str) -> bool {
        if self.s[self.at..].starts_with(word.as_bytes()) {
            self.at += word.len();
            true
        } else {
            false
        }
    }

    fn value(&mut self) -> Result<Value, Error> {
        match self.s.get(self.at) {
            None => Err(self.err("the document ends early")),
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Ok(Value::Str(self.string()?)),
            Some(b't') if self.eat("true") => Ok(Value::Bool(true)),
            Some(b'f') if self.eat("false") => Ok(Value::Bool(false)),
            Some(b'n') if self.eat("null") => Ok(Value::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.err("not a value")),
        }
    }

    fn nested(&mut self) -> Result<(), Error> {
        self.depth += 1;
        // The snapshot is five deep. This is a wall, not a budget.
        if self.depth > 64 {
            return Err(self.err("nested too deep"));
        }
        Ok(())
    }

    fn object(&mut self) -> Result<Value, Error> {
        self.nested()?;
        self.at += 1;
        let mut fields = Vec::new();
        self.space();
        if self.s.get(self.at) == Some(&b'}') {
            self.at += 1;
            self.depth -= 1;
            return Ok(Value::Obj(fields));
        }
        loop {
            self.space();
            if self.s.get(self.at) != Some(&b'"') {
                return Err(self.err("a field name was expected"));
            }
            let key = self.string()?;
            self.space();
            if self.s.get(self.at) != Some(&b':') {
                return Err(self.err("a colon was expected"));
            }
            self.at += 1;
            self.space();
            let v = self.value()?;
            fields.push((key, v));
            self.space();
            match self.s.get(self.at) {
                Some(b',') => self.at += 1,
                Some(b'}') => {
                    self.at += 1;
                    self.depth -= 1;
                    return Ok(Value::Obj(fields));
                }
                _ => return Err(self.err("a comma or the end of the object was expected")),
            }
        }
    }

    fn array(&mut self) -> Result<Value, Error> {
        self.nested()?;
        self.at += 1;
        let mut items = Vec::new();
        self.space();
        if self.s.get(self.at) == Some(&b']') {
            self.at += 1;
            self.depth -= 1;
            return Ok(Value::Arr(items));
        }
        loop {
            self.space();
            items.push(self.value()?);
            self.space();
            match self.s.get(self.at) {
                Some(b',') => self.at += 1,
                Some(b']') => {
                    self.at += 1;
                    self.depth -= 1;
                    return Ok(Value::Arr(items));
                }
                _ => return Err(self.err("a comma or the end of the array was expected")),
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, Error> {
        let digits = self.s.get(self.at..self.at + 4).ok_or(self.err("a short \\u escape"))?;
        let text = std::str::from_utf8(digits).map_err(|_| self.err("a bad \\u escape"))?;
        let n = u32::from_str_radix(text, 16).map_err(|_| self.err("a bad \\u escape"))?;
        self.at += 4;
        Ok(n)
    }

    fn string(&mut self) -> Result<String, Error> {
        self.at += 1;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let b = *self.s.get(self.at).ok_or(self.err("a string that does not end"))?;
            self.at += 1;
            match b {
                b'"' => break,
                b'\\' => {
                    let e = *self.s.get(self.at).ok_or(self.err("a string that does not end"))?;
                    self.at += 1;
                    let c = match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let hi = self.hex4()?;
                            let code = if (0xd800..0xdc00).contains(&hi) {
                                // Half of a pair: the other half has to follow.
                                if !self.eat("\\u") {
                                    return Err(self.err("half a surrogate pair"));
                                }
                                let lo = self.hex4()?;
                                if !(0xdc00..0xe000).contains(&lo) {
                                    return Err(self.err("half a surrogate pair"));
                                }
                                0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00)
                            } else {
                                hi
                            };
                            char::from_u32(code).ok_or(self.err("not a character"))?
                        }
                        _ => return Err(self.err("an escape JSON does not have")),
                    };
                    out.extend_from_slice(c.encode_utf8(&mut [0u8; 4]).as_bytes());
                }
                0..=0x1f => return Err(self.err("a control character inside a string")),
                _ => out.push(b),
            }
        }
        String::from_utf8(out).map_err(|_| self.err("a string that is not UTF-8"))
    }

    fn number(&mut self) -> Result<Value, Error> {
        let from = self.at;
        while let Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9') = self.s.get(self.at) {
            self.at += 1;
        }
        let text = std::str::from_utf8(&self.s[from..self.at]).map_err(|_| self.err("a bad number"))?;
        if let Ok(n) = text.parse::<u64>() {
            // `u64::from_str` takes a leading `+` and leading zeros; JSON does not.
            if text.starts_with('+') || (text.len() > 1 && text.starts_with('0')) {
                return Err(self.err("a bad number"));
            }
            return Ok(Value::Int(n));
        }
        text.parse::<f64>().map(Value::Float).map_err(|_| self.err("a bad number"))
    }
}

/// A string as JSON writes one.
pub fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn what_the_core_writes_is_read() {
        let v = parse(r#"{"a":1,"b":[true,null,"x\n\u4e2d\ud83d\ude00"],"c":{"d":1700006000000}}"#).unwrap();
        assert_eq!(v.get("a"), Some(&Value::Int(1)));
        assert_eq!(
            v.get("b"),
            Some(&Value::Arr(vec![Value::Bool(true), Value::Null, Value::Str("x\n中😀".into())]))
        );
        assert_eq!(v.get("c").and_then(|c| c.get("d")), Some(&Value::Int(1_700_006_000_000)));
        assert_eq!(v.get("missing"), None);
    }

    #[test]
    fn what_it_could_not_have_written_is_refused() {
        for bad in [
            "", "{", "[1,]", "{\"a\":1,}", "{\"a\" 1}", "{a:1}", "\"open", "01", "+1", "nul",
            "{} x", "\"\\q\"", "\"\\ud83d\"", "\"tab\there\"",
        ] {
            assert!(parse(bad).is_err(), "{bad:?} was read");
        }
    }

    #[test]
    fn a_string_goes_out_as_one_string() {
        assert_eq!(quote("a\"b\\c\nd"), r#""a\"b\\c\nd""#);
        assert_eq!(parse(&quote("发票 \u{1} \"x\"")).unwrap(), Value::Str("发票 \u{1} \"x\"".into()));
    }
}
