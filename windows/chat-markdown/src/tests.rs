use super::*;

fn doc(source: &str) -> Document {
    match parse(source) {
        Parsed::Document(d) => d,
        Parsed::PlainFallback(r) => panic!("expected a document, got fallback {r:?} for {source:?}"),
    }
}

fn runs_of(block: &Block) -> &[Run] {
    match block {
        Block::Paragraph(r) | Block::Heading { runs: r, .. } | Block::Quote { runs: r, .. } => r,
        Block::ListItem(item) => &item.runs,
        _ => &[],
    }
}

#[test]
fn headings_paragraphs_and_inline_styles_combine() {
    let d = doc("# Title\n\nSome **bold** and *italic* and `code`.");
    assert!(matches!(d.blocks[0], Block::Heading { level: 1, .. }));
    assert!(visible_text(&d).contains("Title"));
    let p = runs_of(&d.blocks[1]);
    let text: String = p.iter().map(|r| r.text.as_str()).collect();
    assert_eq!(text, "Some bold and italic and code.");
    assert!(p.iter().any(|r| r.text == "bold" && r.style.strong));
    assert!(p.iter().any(|r| r.text == "italic" && r.style.emphasis));
    assert!(p.iter().any(|r| r.text == "code" && r.style.code));
}

#[test]
fn a_fence_keeps_its_own_lines_and_is_not_parsed_as_markdown() {
    let d = doc("```rust\nlet **x** = 1;\n```");
    let Block::Code { language, text } = &d.blocks[0] else {
        panic!("expected a code block");
    };
    assert_eq!(language.as_deref(), Some("rust"));
    assert!(text.contains("let **x** = 1;"), "{text:?}");
    // An unclosed fence is still a code block with all its text.
    let open = doc("```\nstill a fence\nmore");
    let Block::Code { text, .. } = &open.blocks[0] else {
        panic!("expected a code block");
    };
    assert!(text.contains("still a fence") && text.contains("more"));
}

#[test]
fn lists_keep_ordinal_depth_and_task_markers() {
    let d = doc("1. one\n2. two\n   - [x] nested task");
    let items: Vec<&ListItem> = d
        .blocks
        .iter()
        .filter_map(|b| match b {
            Block::ListItem(i) => Some(i),
            _ => None,
        })
        .collect();
    assert!(!items.is_empty());
    assert_eq!(items[0].kind, ListKind::Ordered);
    assert_eq!(items[0].ordinal, 1);
    assert_eq!(items[1].ordinal, 2);
    let task = items.iter().find(|i| i.checked.is_some()).expect("a task");
    assert_eq!(task.checked, Some(true));
    assert!(task.depth >= 2, "nested list depth");
}

#[test]
fn a_quote_carries_its_depth() {
    let d = doc("> outer\n>\n> > inner");
    assert!(d
        .blocks
        .iter()
        .any(|b| matches!(b, Block::Quote { depth: 2, .. })));
    assert!(d.blocks.iter().any(|b| matches!(b, Block::Quote { depth: 1, .. })));
}

#[test]
fn a_table_keeps_alignment_empty_cells_escaped_pipes_and_code() {
    let d = doc("| a | b | c |\n|:--|:-:|--:|\n| 1 |  | `x\\|y` |");
    assert!(
        matches!(d.blocks.first(), Some(Block::Table(_))),
        "a pipe table is a Table block, got {:?}",
        d.blocks
    );
    let Block::Table(t) = &d.blocks[0] else {
        unreachable!()
    };
    assert_eq!(t.columns, vec![Align::Left, Align::Center, Align::Right]);
    assert_eq!(t.header.len(), 3);
    assert_eq!(t.rows.len(), 1);
    assert_eq!(t.rows[0].len(), 3, "empty cell must not collapse a column");
    assert!(t.rows[0][1].is_empty(), "the middle cell is empty");
    let code = &t.rows[0][2];
    assert!(code.iter().any(|r| r.style.code && r.text == "x|y"));
}

#[test]
fn a_table_header_keeps_each_cell_verbatim() {
    let d = doc("| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |");
    let Block::Table(t) = &d.blocks[0] else {
        panic!("expected a table");
    };
    assert_eq!(t.header.len(), 3);
    let texts: Vec<String> = t
        .header
        .iter()
        .map(|cell| cell.iter().map(|r| r.text.as_str()).collect())
        .collect();
    assert_eq!(texts, vec!["a", "b", "c"]);
    assert_eq!(t.columns, vec![Align::Left, Align::Left, Align::Left]);
}

#[test]
fn a_trailing_html_block_keeps_its_text_after_a_heading() {
    let d = doc("# title\n\n<div>tail</div>\n");
    let text = visible_text(&d);
    assert!(text.contains("title"), "{text:?}");
    assert!(text.contains("tail"), "the trailing HTML block was swallowed: {text:?}");
}

#[test]
fn breaks_are_visible_and_html_is_literal_and_images_keep_alt_only() {
    let d = doc("line one\nline two\n\n<br> ![alt text](https://example.invalid/x.png)");
    let text = visible_text(&d);
    assert!(text.contains("line one\nline two"), "{text:?}");
    assert!(text.contains("<br>"));
    assert!(text.contains("alt text"));
    assert!(!text.contains("https://example.invalid/x.png"));
}

#[test]
fn a_complex_list_item_is_a_whole_message_fallback() {
    match parse("- first\n\n  second paragraph") {
        Parsed::PlainFallback(Reason::Unsupported) => {}
        other => panic!("expected Unsupported, got {other:?}"),
    }
}

#[test]
fn empty_input_is_an_empty_document_not_a_fallback() {
    let d = doc("");
    assert!(d.blocks.is_empty());
}

#[test]
fn a_non_empty_message_with_no_block_is_a_fallback_not_an_empty_page() {
    // Whitespace only: non-empty source, nothing the model can show. The
    // caller keeps the original text; this must not read as an empty chat.
    for source in ["   \n\t\n", "\n\n", "  \r\n"] {
        assert_eq!(
            parse(source),
            Parsed::PlainFallback(Reason::Unsupported),
            "{source:?} must not become an empty document"
        );
    }
    // Empty is still a legal empty document.
    assert!(matches!(parse(""), Parsed::Document(_)));
}

#[test]
fn nesting_counts_every_tag_not_only_blocks() {
    // A paragraph is one level; the emphasis inside is the second. With a
    // budget of one, the inline tag is what crosses it -- so inline depth
    // is part of the same count.
    let one = Limits {
        nesting: 1,
        ..Limits::default()
    };
    assert_eq!(parse_with_limits("plain", one), Parsed::Document(Document { blocks: doc("plain").blocks }));
    assert_eq!(
        parse_with_limits("a *b*", one),
        Parsed::PlainFallback(Reason::Limit)
    );
}

#[test]
fn the_parse_bounds_refuse_without_reading_further() {
    let limits = Limits {
        input_bytes: 4,
        ..Limits::default()
    };
    assert_eq!(parse_with_limits("12345", limits), Parsed::PlainFallback(Reason::Limit));

    let mut nested = String::new();
    for _ in 0..40 {
        nested.push('>');
    }
    nested.push_str(" x");
    assert_eq!(parse(&nested), Parsed::PlainFallback(Reason::Limit));

    let limits = Limits {
        blocks: 0,
        ..Limits::default()
    };
    assert_eq!(
        parse_with_limits("# a", limits),
        Parsed::PlainFallback(Reason::Limit)
    );

    // Two paragraphs against a one-block budget.
    let one_block = Limits {
        blocks: 1,
        ..Limits::default()
    };
    assert_eq!(
        parse_with_limits("a\n\nb", one_block),
        Parsed::PlainFallback(Reason::Limit)
    );

    // A single run budget sees the second styled run.
    let one_run = Limits {
        runs: 1,
        ..Limits::default()
    };
    assert_eq!(
        parse_with_limits("a **b**", one_run),
        Parsed::PlainFallback(Reason::Limit)
    );

    // More columns than the bound allows, before any cell is built.
    let wide: String = (0..65).map(|i| format!("| c{i} ")).collect::<String>() + "|\n";
    let rule: String = (0..65).map(|_| "|---").collect::<String>() + "|\n";
    assert_eq!(
        parse(&(wide + &rule)),
        Parsed::PlainFallback(Reason::Limit)
    );

    // Cells: one cell allowed, a two-cell table needs two.
    let one_cell = Limits {
        table_cells: 1,
        ..Limits::default()
    };
    assert_eq!(
        parse_with_limits("| a | b |\n|---|---|\n| 1 | 2 |", one_cell),
        Parsed::PlainFallback(Reason::Limit)
    );
}

#[test]
fn the_cache_never_answers_across_identity() {
    let mut cache = Cache::with_limits(10, 1_000_000);
    let key = |group: &str, gen: u64, anchor: &str, version: u64| Key {
        group: group.to_owned(),
        generation: gen,
        anchor: anchor.to_owned(),
        content_version: version,
    };
    cache.parse_cached(key("g", 1, "a:1", 0), "# one");
    assert!(cache.get(&key("g", 1, "a:1", 0)).is_some());
    for miss in [
        key("h", 1, "a:1", 0),
        key("g", 2, "a:1", 0),
        key("g", 1, "a:2", 0),
        key("g", 1, "a:1", 1),
    ] {
        assert!(cache.get(&miss).is_none(), "{miss:?} must miss");
    }
}

#[test]
fn the_cache_is_lru_and_bounded_and_fallbacks_cost_little() {
    let mut cache = Cache::with_limits(2, 1_000_000);
    let key = |anchor: &str| Key {
        group: "g".to_owned(),
        generation: 1,
        anchor: anchor.to_owned(),
        content_version: 0,
    };
    cache.parse_cached(key("a"), "a");
    cache.parse_cached(key("b"), "b");
    // Touching a keeps it from being the one evicted.
    assert!(cache.get(&key("a")).is_some());
    cache.parse_cached(key("c"), "c");
    assert!(cache.get(&key("b")).is_none(), "the least recent is gone");
    assert!(cache.get(&key("a")).is_some());
    assert_eq!(cache.len(), 2);

    // A fallback keeps its reason, not its source.
    let mut cache = Cache::with_limits(10, 1_000_000);
    let parsed = cache.parse_cached(key("f"), "- a\n\n  b");
    assert!(matches!(parsed, Entry::PlainFallback(Reason::Unsupported)));
    let entry = cache.get(&key("f")).expect("cached");
    assert!(matches!(entry, Entry::PlainFallback(Reason::Unsupported)));
    assert!(cache.bytes() < 1024);
}

#[test]
fn the_byte_budget_evicts_and_refuses_an_entry_that_cannot_fit() {
    let mut cache = Cache::with_limits(100, 200);
    let key = |anchor: &str| Key {
        group: "g".to_owned(),
        generation: 1,
        anchor: anchor.to_owned(),
        content_version: 0,
    };
    cache.parse_cached(key("a"), &"x".repeat(100));
    assert!(cache.bytes() <= 200);
    // Far larger than the whole budget: not cached at all.
    let mut small = Cache::with_limits(100, 100);
    let parsed = small.parse_cached(key("big"), &"y".repeat(10_000));
    assert!(matches!(parsed, Entry::Document(_)), "parsed, just not cached");
    assert!(small.is_empty());
}
