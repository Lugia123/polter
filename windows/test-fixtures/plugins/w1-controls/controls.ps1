# Not a real plugin: it exists so the settings page has something with one
# parameter of each shape. It is never started by the tests -- what is being
# checked is the page and the settings file, not a running plugin -- but a
# manifest whose `exec` names nothing at all would be refused at load.
exit 0
