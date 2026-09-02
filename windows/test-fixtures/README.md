# Fixtures

**Not shipped.** Nothing here is copied into `zig-out` or into a release: the
set of plugins a build ships is a fact about the product, and a fixture that
lived in `plugins/` would change it.

## `plugins/w1-controls`

One parameter of each shape the settings page can draw -- text, a closed set,
and a boolean. The boolean is why it exists: **no shipped plugin declares one**
(they use `enum: ["yes","no"]`), so the checkbox branch of `control_of` had
never been drawn on a real page, and the string round-trip it implies had never
been exercised.

To use it, copy the directory into the user plugin directory on the machine
under test -- the one `[plug] config dir …` names in the log -- and open the
settings page. Delete it afterwards; it does nothing and it is not a plugin
anybody should be left with.

## A note this directory earned

The first version of `w1-controls` wrote its self-description under a
`summary` key -- because the host's manifest reader looked for `summary`, and
the fixture was written to match the host. **The manifests that ship use
`description`, and so do the core and the macOS app**; the reader was wrong,
and the fixture agreed with it.

That is the failure a fixture has and an outside ruler does not: *a fixture is
written by whoever wrote the code, so it inherits the same mistake and then
passes.* The parameter-count test next to it reads the four real shipped
manifests through `include_str!` for exactly this reason -- they were written
by somebody else, before the bug, and they are the only thing in reach that
could say the reader was looking in the wrong place.

