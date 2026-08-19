# Changelog

## 0.1.0 - unreleased

First feature-complete build: a live combat meter, a death cause window that explains what
killed you, a full post-combat analysis window with a session history, graphs and a skill
breakdown table, and an options panel. Not yet tested in-game -- treat this as a first build to
load and shake out.

Fixed: the analysis window's skill table failed to load (`attempt to call field 'ScrollView'`)
-- `Turbine.UI.ScrollView` isn't a real class. Switched to the real `Turbine.UI.ListBox` +
`Turbine.UI.Lotro.ScrollBar` pattern.

Fixed: no combat was ever recorded (`/reck dump` always said "no session data yet"). Two bugs
stacked on top of each other -- the chat listener read `args.Type` instead of the real
`args.ChatType`, and separately `LocalPlayer.name` (used to tell "my own damage" from everyone
else's) was never actually set to a real name, since it isn't a real Turbine property. Both
fixed; combat should record correctly now.

Fixed: every "selected"/tint effect (selected tabs, selected session, selected picker chip,
skill-table share bars, the graph's gridlines and data columns, KPI card backgrounds) was
rendering as full solid colour instead of a subtle wash -- the engine doesn't blend opacity the
way that code assumed. Switched to precomputed blended colours throughout. Also: session-rail pin
markers showed as "?" (the diamond characters the design uses aren't in this client's font) --
now a small filled square instead.

Changed: the live meter now stays on screen permanently whenever enabled, instead of hiding 8
seconds after a fight ends. It shows the live fight, the last finished one, or a zeroed idle
state if nothing's been fought yet, dimming when out of combat rather than disappearing.

Added `/reck testdeath` -- pops the death window with synthesized data, for checking the window
itself works independently of whether a real death has actually been detected.
