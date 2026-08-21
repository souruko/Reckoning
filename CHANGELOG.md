# Changelog

## 0.3.0 - unreleased

**Search boxes on the skill table and the self-buff table.** Type any part of a skill, damage type,
attacker or buff name to narrow the list down to matching rows.

**Both tables sort by any column.** Click a heading to sort by it, click the same heading again to
reverse the order.

**A draggable splitter between the skill table and the SELF BUFFS row.** Drag it to give either
section more room, and it remembers where you put it. The buff section's collapse arrow is gone --
dragging the splitter to the bottom does the same job.

**The analysis window can now be as tall as your screen**, instead of stopping at a fixed height.

**Escape closes a window**, same as clicking its close button.

**Window buttons are proper icons now** -- the close button, the session pins and the search box's
magnifying glass and clear button were all plain text characters before.

**Live meter:** the big headline number is your damage or healing per second now, with the raw
total moved to the small line in the corner -- they used to be the other way round. The button
that opens the analysis window also closes it again on a second click.

**Self-buffs are listed worst uptime first**, so the ones you let drop are at the top instead of
buried under everything you held at 100%.

**Fixed: targets past the fifth were unreachable in the analysis window's picker.** In a fight with
more than a handful of enemies the chips ran off the right-hand edge of the window with no way to
get at them. They now wrap onto two rows with a "+N more" chip that opens up the rest, and long
names are shortened to fit.

**Fixed: the resize gripper was wildly oversensitive** -- dragging the corner made the window run
away from the pointer instead of following it.

**Fixed: dragging a window threw away its saved size** -- and the analysis window's splitter
position along with it -- every single time.

**Fixed: the game could stall for seconds around a death, and got laggier the longer you played.**
The live meter was asking the game for your current target ten times a second, and your morale was
re-read from scratch on every hit you took; both are now only updated when they actually change. A
single bad combat chat line can also no longer break combat tracking for the rest of a fight.

## 0.2.0 - unreleased

The analysis window gets a redesign.

**The graph is now a line plot.** Damage and healing are drawn as real lines with dots on the
data points, instead of the faint shaded columns they used to be. Hovering anywhere on the plot
still shows the numbers for that moment.

**Morale is now a background bar graph.** On the "Damage taken" and "Healing taken" views your
morale is drawn as bars behind the lines, with guide lines at full and half, and the stretches
where you dropped below 30% picked out in a warning colour so a near-death moment is obvious at a
glance. It used to be a thin row of dots above the plot. The legend now reads out the peak and
low morale for whatever part of the fight you are looking at.

**A time-range slider.** Drag either handle under the plot to zoom in on part of a fight -- the
KPIs, the skill table, the side panels and the buff table all recount for just those seconds, and
the header tells you which slice you are looking at. "RESET RANGE" puts it back.

**Self-buff tracking.** A new SELF BUFFS table under the skill table shows uptime %, total
uptime, how many times it was applied, and the longest stretch you went without it, for every
buff you had during the fight. Click a row to chart it -- up to three at a time -- and it gets
its own timeline under the graph showing exactly when it was up. Click the header to collapse the
section. Mounts and travel skills are filtered out; `/reck buffs ignore <name>` filters out
anything else you don't care about, and `/reck buffs` lists what is being tracked. The table
scrolls when a fight tracked more buffs than fit in the space it was given, instead of just
cutting the list off.

**Fixed: the skill table's last column was cut off.** On the "Damage taken" view the table was
wider than the space it had, so TOTAL -- the one number you can least afford to lose -- ran off
the right-hand edge. The separate CRIT and DEV columns are now a single "CRIT / DEV" column
showing percentages, and the table uses the window's full width.

**Fixed: the KPI cards overlapped themselves.** The big number and the small line under it were
drawn on top of each other by 6px.

**Fixed: self-buff icons weren't showing.** The buff table and the graph's charted-buff lanes
were showing a blank placeholder tile instead of the buff's actual icon.

Tabs are reordered to Damage done / Damage taken / Healing done / Healing taken, so the two views
you compare sit next to each other, and their labels are centred.

**Live meter:** the headline now has a 30-second sparkline under it, so you can see whether your
damage is climbing or falling off without opening anything. Tabs are underlined rather than
filled blocks. Same window size as before.

**Death window:** the biggest single hit is now marked as well as the killing blow -- they are
often not the same hit, and knowing which one actually did the damage is the point. Both marked
rows get a tinted background and a coloured edge instead of just a coloured number, and each row
now prints its morale percentage next to the bar.

**Performance pass.** Every window colour used to be rebuilt from scratch on every refresh; colours
are now resolved once and reused, which cuts out a lot of repeated work during combat -- most
noticeably in the live meter's sparkline (updates 10 times a second) and the analysis graph's
morale bars. The live meter's damage/heal rate no longer rescans the whole fight's timeline on
every refresh. The death window's countdown number now only redraws when the second it's showing
actually changes, instead of every rendered frame.

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

Fixed: the death window still never appeared on a real death, even though `/reck testdeath`
proved the window itself worked. Defeat/incapacitate lines ("The X incapacitated you.", "You
succumb to your wounds.") arrive on their own chat channel, separate from the one regular
damage/healing lines use -- they were being filtered out before ever reaching the parser. Found
by testing the real parser and dispatch code against a combat log the user captured and shared.

Changed: the live meter no longer dims when out of combat -- always full opacity now, per
feedback.

Changed: the death window now pauses its auto-hide countdown while the mouse is over it, instead
of counting down regardless -- reading the cause no longer races the popup closing.

Fixed: the analysis window's target/source picker -- clicking a chip could filter by the wrong
target entirely (a different one than the chip's own label), and the "All targets" chip could
end up pointing at a specific target instead of clearing the filter. A `{nil}` table used as the
start of an array, followed by `table.insert`, is broken in Lua: a table with a leading nil has
an undefined/zero length, so the insert silently overwrote that slot instead of appending after
it, shifting every chip's filter value one position off from its label.

Fixed: the analysis window's graph looked completely empty even with real combat data. The
13%-opacity area fill alone is too faint to read against the panel background -- added a solid
"cap" line on top of each bar, closer to what the design's "area fill under a line" actually
specifies. That alone wasn't the whole bug, though -- the graph's container never actually had a
size set on it (only a position), so it never rendered its contents at all regardless of the
cap fix. Both fixed now.

Changed: the live meter's header now doubles as a small button bar -- the "LAST FIGHT" text is
gone, replaced with a button that opens the analysis window. The combat-state indicator is now
just "IN COMBAT"/"IDLE", conveyed by the accent tick's colour as well as the text.

Changed: the live meter now refreshes 10 times a second instead of 5.

Fixed: the live meter's "largest hit" line could overflow badly and overlap the label next to it
when the skill name was long -- now truncated to a bounded total width.

Changed: the death window's time column showed unreadable/overflowing values -- switched from a
one-decimal format to whole seconds and widened the column. Morale is now shown as a small bar
per row (matching the analysis window's own bars) instead of a raw percentage number.

Changed: the analysis window's graph now has a timeline (elapsed-time labels) under the plot,
and the morale trace gets its own reserved lane at the top of the plot instead of sharing space
with the damage/heal bars -- it was reportedly confusing when the dots and bars overlapped.

Changed: the live meter's "largest hit" skill name is a smaller line below the number now,
instead of squeezed onto the same line -- per feedback that the earlier truncated-single-line
version wasn't wanted.

Added: hovering a column in the analysis window's graph shows a tooltip with the elapsed time
and each series' value at that point, plus morale if the view carries it.

Added: the morale trace now shows the peak morale % reached, not just the word "MORALE".

Fixed: the analysis window's graph ignored the target/source picker -- it always showed the
pooled (all-targets) data even when filtered to one target. Now respects the filter, the same
way the KPIs/table/side panels already did.
