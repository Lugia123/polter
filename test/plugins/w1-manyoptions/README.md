# `w1-manyoptions` — the instrument for task 138

**Not a plugin anybody should install.** It exists so a drop-down with more
options than the list can show at once can be opened on the test machine, and
it is checked in because the alternative is authoring it there, by hand, on the
one machine that is the bottleneck.

Copy the `w1-manyoptions` directory into the host's plugin directory (the one
`[plug] config dir …` names in the log) and open **Settings ▸ Forty options**.

Two parameters, and the second one is not decoration:

| parameter | what it is for |
| --- | --- |
| `many` | 40 options. More than the drop-down's default cap of 30, which is the condition under test. |
| `few` | 3 options. **The control.** A list shorter than the cap must keep behaving exactly as it does today -- `CB_SETMINVISIBLE` is a *minimum*, so this one should still show three rows and no scroll bar. If this one changes, the fix has side effects on every existing plugin. |

`exec` names a script that is not here. Nothing in this test runs the plugin;
the settings page reads the manifest and draws controls from it, which is the
whole of what is being exercised. If a future check does try to run it, that is
the moment to add the file rather than now -- an executable that exists only so
a field is not empty is one more thing that can be run by accident.
