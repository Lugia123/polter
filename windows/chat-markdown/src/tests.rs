use super::*;
use std::sync::Arc;

fn doc(source: &str) -> Document {
    match parse(source) {
        Parsed::Document(d) => d,
        Parsed::PlainFallback(r) => {
            panic!("expected a document, got fallback {r:?} for {source:?}")
        }
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
    let Block::Code { language, text, .. } = &d.blocks[0] else {
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
    assert!(d
        .blocks
        .iter()
        .any(|b| matches!(b, Block::Quote { depth: 1, .. })));
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
    assert!(
        text.contains("tail"),
        "the trailing HTML block was swallowed: {text:?}"
    );
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
    assert_eq!(
        parse_with_limits("plain", one),
        Parsed::Document(Document {
            blocks: doc("plain").blocks
        })
    );
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
    assert_eq!(
        parse_with_limits("12345", limits),
        Parsed::PlainFallback(Reason::Limit)
    );

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
    assert_eq!(parse(&(wide + &rule)), Parsed::PlainFallback(Reason::Limit));

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
fn the_cost_counts_containers_and_link_bytes_not_only_text() {
    let key = Key {
        group: "g".to_owned(),
        generation: 1,
        anchor: "a".to_owned(),
        content_version: 0,
    };
    let long = "https://example.invalid/a/very/long/link";
    let mut runs = Vec::new();
    for i in 0..300 {
        runs.push(Run {
            spans: Vec::new(),
            text: if i % 2 == 0 {
                "a".to_owned()
            } else {
                "b".to_owned()
            },
            style: Style {
                link: Some(Arc::from(long)),
                ..Style::default()
            },
        });
    }
    let dense = Document {
        blocks: vec![Block::Paragraph(runs)],
    };
    let cost = cache::cost(&key, &Entry::Document(Arc::new(dense)));
    assert!(
        cost > 300 * (std::mem::size_of::<Run>() + long.len()),
        "containers and link bytes are counted: {cost}"
    );

    // A table of empty cells: each cell's Vec descriptor counts even with
    // no runs in it, so a budget is not fooled by "no text".
    let row: Vec<Vec<Run>> = (0..8).map(|_| Vec::new()).collect();
    let table = Table {
        columns: vec![Align::Left; 8],
        header: row.clone(),
        rows: vec![row; 16],
    };
    let cells = 8 * 17;
    let doc = Document {
        blocks: vec![Block::Table(table.clone())],
    };
    let cell_cost = cache::cost(&key, &Entry::Document(Arc::new(doc)));
    assert!(
        cell_cost > cells * std::mem::size_of::<Vec<Run>>(),
        "empty cells still cost their descriptor: {cell_cost}"
    );
    let mut small = Cache::with_limits(10, 1024);
    small.insert(
        key.clone(),
        Entry::Document(Arc::new(Document {
            blocks: vec![Block::Table(table)],
        })),
    );
    assert!(
        small.is_empty(),
        "an entry this size is refused, not miscounted in"
    );
    assert_eq!(small.bytes(), 0);
}

#[test]
fn one_long_link_is_one_shared_allocation_across_styled_runs() {
    let d = doc("[**a** *b* `c`](https://example.invalid/very/long/path?query=1)");
    let runs = runs_of(&d.blocks[0]);
    let links: Vec<&Arc<str>> = runs.iter().filter_map(|r| r.style.link.as_ref()).collect();
    assert!(
        links.len() >= 2,
        "styled runs share one link style: {runs:?}"
    );
    for link in &links {
        assert!(
            Arc::ptr_eq(links[0], link),
            "the link bytes are one allocation"
        );
    }
}

#[test]
fn a_cache_hit_shares_the_same_document_allocation() {
    let mut c = Cache::with_limits(10, 1 << 20);
    let key = Key {
        group: "g".to_owned(),
        generation: 1,
        anchor: "a".to_owned(),
        content_version: 0,
    };
    let Entry::Document(first) = c.parse_cached(key.clone(), "# t") else {
        panic!("expected a document");
    };
    let Entry::Document(second) = c.parse_cached(key.clone(), "# t") else {
        panic!("expected a document");
    };
    assert!(
        Arc::ptr_eq(&first, &second),
        "a hit shares, it does not clone"
    );
    let Entry::Document(held) = c.peek(&key).expect("cached") else {
        panic!("expected a document");
    };
    assert!(Arc::ptr_eq(&first, held));
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
    assert!(
        matches!(parsed, Entry::Document(_)),
        "parsed, just not cached"
    );
    assert!(small.is_empty());
}

#[test]
fn a_link_keeps_the_destination_exactly_as_the_message_wrote_it() {
    // **A backslash before a space is not a CommonMark escape.** The space
    // ends an un-delimited destination, so `b.md "title"` is not a title
    // and the source is literal text: there is no link, and no raw
    // destination to reconstruct. This fixture used to assert one.
    let plain = doc("[a](docs/a\\ b.md \"title\")");
    let runs = match &plain.blocks[0] {
        Block::Paragraph(runs) => runs,
        other => panic!("expected a paragraph, got {other:?}"),
    };
    assert!(
        runs.iter().all(|r| r.style.link_raw.is_none()),
        "a non-link must not carry a raw destination"
    );

    // The escapes CommonMark does honour stay as the source wrote them.
    let d = doc("[a](docs/a\\)b.md \"title\")");
    let runs = match &d.blocks[0] {
        Block::Paragraph(runs) => runs,
        other => panic!("expected a paragraph, got {other:?}"),
    };
    assert_eq!(
        runs[0].style.link_raw.as_deref(),
        Some("docs/a\\)b.md"),
        "the backslash is the source's, not a reconstruction"
    );
    let angle = doc("[b](<docs/c d.md>)");
    let runs = match &angle.blocks[0] {
        Block::Paragraph(runs) => runs,
        other => panic!("expected a paragraph, got {other:?}"),
    };
    assert_eq!(runs[0].style.link_raw.as_deref(), Some("docs/c d.md"));
}

#[test]
fn a_raw_reference_stops_at_this_links_own_closing_paren() {
    let link_raw = |source: &str, index: usize| {
        let d = doc(source);
        let runs = match &d.blocks[0] {
            Block::Paragraph(runs) => runs,
            Block::ListItem(item) => &item.runs,
            other => panic!("expected runs, got {other:?}"),
        };
        runs[index].style.link_raw.clone()
    };
    assert_eq!(link_raw("[a](a.md) 后文", 0).as_deref(), Some("a.md"));
    assert_eq!(link_raw("[a](a.md)[b](b.md)", 0).as_deref(), Some("a.md"));
    assert_eq!(link_raw("[a](a.md)[b](b.md)", 1).as_deref(), Some("b.md"));
    assert_eq!(
        link_raw("[a](docs/a\\)b.md)", 0).as_deref(),
        Some("docs/a\\)b.md")
    );
    assert_eq!(link_raw("[a][ref] [b](b.md)", 0), None);
    assert_eq!(link_raw("[a][ref] [b](b.md)", 1).as_deref(), Some("b.md"));
}

#[test]
fn a_raw_reference_in_a_table_cell_keeps_its_own_text() {
    let d = doc("| x |\n| --- |\n| [a](a.md) |");
    let table = match &d.blocks[0] {
        Block::Table(t) => t,
        other => panic!("expected a table, got {other:?}"),
    };
    let runs = &table.rows[0][0];
    assert_eq!(runs[0].style.link_raw.as_deref(), Some("a.md"));
}

// ------------------------------------------------- rendered source ranges

/// The rendered text of `source` that a raw byte range covers. Every test
/// below goes through the same helper the host paints from.
fn shown_for(source: &str, range: std::ops::Range<usize>) -> Vec<String> {
    let d = doc(source);
    let runs = match &d.blocks[0] {
        Block::Paragraph(runs) => runs,
        other => panic!("expected a paragraph, got {other:?}"),
    };
    let mut out = Vec::new();
    for r in display_ranges(&runs[0].spans, range) {
        if let Some(s) = runs[0].text.get(r) {
            out.push(s.to_owned());
        }
    }
    out
}

fn range_of(hay: &str, needle: &str) -> std::ops::Range<usize> {
    let at = hay.find(needle).expect("the needle is in the source");
    at..at + needle.len()
}

#[test]
fn a_hit_in_chinese_and_emoji_maps_to_the_same_rendered_bytes() {
    let source = "前缀 中文 🎉 后缀";
    assert_eq!(shown_for(source, range_of(source, "中文")), vec!["中文"]);
    // A range covering the whole emoji, not one byte of it: the mapping
    // never treats UTF-8 bytes as characters.
    assert_eq!(shown_for(source, range_of(source, "🎉")), vec!["🎉"]);
    // The answer is a display byte range, so slicing the run is safe.
    let d = doc(source);
    let Block::Paragraph(runs) = &d.blocks[0] else {
        panic!("a paragraph");
    };
    let r = display_ranges(&runs[0].spans, range_of(source, "🎉"));
    assert_eq!(r.len(), 1);
    assert!(runs[0].text.is_char_boundary(r[0].start));
    assert!(runs[0].text.is_char_boundary(r[0].end));
}

#[test]
fn escapes_and_entities_map_their_whole_source_unit_to_one_character() {
    // `\*` is a real CommonMark escape: source two bytes, display one.
    let escaped = "a \\* b";
    assert_eq!(shown_for(escaped, range_of(escaped, "\\*")), vec!["*"]);
    // `&amp;` is decoded: source five bytes, display one.
    let entity = "a &amp; b";
    assert_eq!(shown_for(entity, range_of(entity, "&amp;")), vec!["&"]);
    // A numeric entity keeping a Chinese character is one unit too.
    let numeric = "x &#20013; y";
    assert_eq!(shown_for(numeric, range_of(numeric, "&#20013;")), vec!["中"]);
}

#[test]
fn a_hit_in_a_fenced_code_block_maps_to_its_line() {
    let source = "```\nlet 中文 = \"🎉\";\n```";
    let d = doc(source);
    let Block::Code { text, spans, .. } = &d.blocks[0] else {
        panic!("a code block");
    };
    let hit = range_of(source, "🎉");
    let shown: Vec<&str> = display_ranges(spans, hit)
        .into_iter()
        .filter_map(|r| text.get(r))
        .collect();
    assert_eq!(shown, vec!["🎉"]);
}

#[test]
fn a_hit_in_a_table_cell_maps_to_that_cell_only() {
    let source = "| 名称 | 值 |\n| --- | --- |\n| 中文 | 🎉 ok |";
    let d = doc(source);
    let Block::Table(t) = &d.blocks[0] else {
        panic!("a table");
    };
    let cell = &t.rows[0][1];
    let hit = range_of(source, "🎉");
    let shown: Vec<&str> = display_ranges(&cell[0].spans, hit)
        .into_iter()
        .filter_map(|r| cell[0].text.get(r))
        .collect();
    assert_eq!(shown, vec!["🎉"]);
}

#[test]
fn an_unparseable_transform_does_not_claim_a_range() {
    // An entity outside this parser's decoding table stops the mapping;
    // the caller gets no range rather than a wrong one.
    let source = "a &bogusentity; b";
    let d = doc(source);
    let Block::Paragraph(runs) = &d.blocks[0] else {
        panic!("a paragraph");
    };
    // If pulldown left it verbatim, the exact path covers it; either way
    // the answer is never a range over unrelated text.
    let shown: Vec<&str> = display_ranges(&runs[0].spans, range_of(source, "bogusentity"))
        .into_iter()
        .filter_map(|r| runs[0].text.get(r))
        .collect();
    assert!(
        shown.is_empty() || shown == ["bogusentity"],
        "unexpected mapping: {shown:?}"
    );
}

// -- hit_ranges_in_piece (task 2997) ----------------------------------------
//
// One mapping feeds both the `search_hit` ground and the `search_hit_text`
// word; these pin its clipping, ordering and boundary rules.

fn exact_span(text: &str) -> Vec<Span> {
    vec![Span {
        text: 0..text.len(),
        source: 0..text.len(),
        exact: true,
    }]
}

#[test]
fn hit_ranges_in_piece_are_relative_to_the_piece() {
    let text = "abcneedlexyz";
    let got = hit_ranges_in_piece(&exact_span(text), text, 3..9, &[0..text.len()]);
    assert_eq!(got, vec![0..6]);
}

#[test]
fn hit_ranges_in_piece_clip_to_the_piece() {
    let text = "abcneedlexyz";
    // The piece covers "needle" only; a wider hit arrives.
    let got = hit_ranges_in_piece(&exact_span(text), text, 3..9, &[2..11]);
    assert_eq!(got, vec![0..6]);
}

#[test]
fn hit_ranges_in_piece_drop_a_hit_outside_the_piece() {
    let text = "abcdef";
    let got = hit_ranges_in_piece(&exact_span(text), text, 0..3, &[3..6]);
    assert!(got.is_empty());
}

#[test]
fn hit_ranges_in_piece_drop_a_range_that_starts_inside_the_previous_one() {
    let text = "abcdef";
    let got = hit_ranges_in_piece(&exact_span(text), text, 0..6, &[1..4, 3..5]);
    assert_eq!(got, vec![1..4]);
}

#[test]
fn hit_ranges_in_piece_keep_a_decoded_unit_whole() {
    // "&" is displayed in one byte for a five-byte source unit.
    let text = "a&b";
    let spans = vec![
        Span { text: 0..1, source: 0..1, exact: true },
        Span { text: 1..2, source: 1..6, exact: false },
        Span { text: 2..3, source: 6..7, exact: true },
    ];
    let got = hit_ranges_in_piece(&spans, text, 0..3, &[3..4]);
    assert_eq!(got, vec![1..2]);
}

#[test]
fn hit_ranges_in_piece_drop_a_range_that_cuts_a_character() {
    let text = "批量";
    assert!(hit_ranges_in_piece(&exact_span(text), text, 0..6, &[1..6]).is_empty());
}
