# Changelog

## 0.1.0 - unreleased

First feature-complete build: a live combat meter, a death cause window that explains what
killed you, a full post-combat analysis window with a session history, graphs and a skill
breakdown table, and an options panel. Not yet tested in-game -- treat this as a first build to
load and shake out.

Fixed: the analysis window's skill table failed to load (`attempt to call field 'ScrollView'`)
-- `Turbine.UI.ScrollView` isn't a real class. Switched to the real `Turbine.UI.ListBox` +
`Turbine.UI.Lotro.ScrollBar` pattern.
