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
