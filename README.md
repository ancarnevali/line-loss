# Line loss

An add-on for [Power Overload](https://mods.factorio.com/mod/PowerOverload) (Factorio 2.1).
Power is lost along the wires between transformers: the farther it travels and the thinner the
poles carrying it, the more is lost. Transformers waste a little of what passes through them, plus
a small constant core loss. Every loss is drawn by a hidden consumer, so it appears in the electric
network statistics and loads your power plants like any other demand.

## Requirements and setup

* Factorio 2.1 and Power Overload 2.3.3 or later.
* Set Power Overload's **Transformer efficiency** map setting to **1 (100%)**. This mod charges
  transformer inefficiency itself, at its own efficiency setting. If Power Overload's is lower, this
  mod's efficiency is ignored (so it is never charged twice) and a one-time warning is shown.

## How it works (short version)

* Each pole type has a **line resistance** (shown in its tooltip): small poles about 5.5 times a big
  pole, huge poles about a third.
* For each transformer the mod measures the resistance-weighted distance along the wires to what it
  feeds. Each route loses 0.025% per tile of that distance, capped at 95%; the transformer is
  charged the sum of what its routes lose, and its **line loss** is that sum as a share of its output.
* A transformer fed directly by generators also pays for the wires to them: each pole is weighted by
  the rated output of the generators next to it, so far-away generators cost more. When several
  transformers draw from the same generators, they are paired like any other sources and consumers.
* Losses are drawn by hidden consumers per transformer: **Line loss** on its downstream network
  (and on its upstream network when that is a generator network), and **Transf. ineff.**
  (inefficiency plus core loss) on its upstream network.

The details, with a worked example, are in **FAQs**.

## Interface

* **Hover a transformer**: the power it draws and its line loss for the last segment, the stage just
  above it, coloured like the grid diagram's diamonds.
* **Transformer panel**: upstream line loss for the last segment and cumulative, downstream line
  loss and power lost, inefficiency, core loss, power drawn and output. Every line
  has a tooltip defining it.
* **Grid diagram** (shortcut bar, map view): a line for each route between transformers, wider
  with more power and coloured by its loss, labelled with power and loss; receiving transformers are marked with a diamond.
* **Grid power panel**: power generated, reaching consumers and lost, averaged over 5 s, and the 5 routes losing the most power.
* **Line-loss map** (shortcut bar, map view): a dot on every pole, coloured by the line loss of the
  power reaching it from its nearest transformer (green under 0.5% to dark red at 50% and above) and
  sized by the power lost delivering the machine load on it. A big red dot is far and heavily
  loaded: where an upgrade saves the most.

## Settings (map)

| Setting | Default | Effect |
|---|---|---|
| Line losses | on | Turns line losses, and the displays that depend on them, on or off |
| Line loss per tile (%) | 0.025 | Loss per tile of resistance-weighted distance |
| Line losses: feed nearest consumers first | on | Each transformer's power goes mostly to the consumers nearest to it (see FAQs.txt) |
| Line losses: weight machines by their live load | off | Machines are located per pole and weighted by what they draw right now, instead of counting as spread evenly; costs extra script time |
| Transformer efficiency | 0.99 | Energy out per energy in |
| Transformer core loss (%) | 0.1 | Constant loss of a switched-on transformer, % of its rating; 0 turns it off |

## Gameplay

* Carry power far on big or huge poles and step down close to the factory; long runs of small poles
  are expensive.
* Feed large networks from several sides.
* Every transformer stage costs its inefficiency, and every switched-on transformer its core loss:
  do not stack or spam them without reason.
* Use the line-loss map and the worst-routes list to see where an upgrade saves the most.

## Performance

"Weight machines by their live load" adds an entity search per pole whenever a network is searched
again, and it searches a network again whenever an electric machine is built or removed on it, so
building large blueprints costs extra script time while bots work.

Distances are searched one transformer at a time. A search runs when its network changes (a pole
built or removed, networks merged or split, a transformer added or removed) at up to 100 poles per
tick, and a slow background pass (10 poles per tick) catches changes no event reports, such as a
wire added inside a network. Power is measured once a second from network statistics and smoothed;
the losses set from it apply from the next tick, so losses follow load changes within a few seconds
(and a transformer hands on the energy it draws one tick later, as in Power Overload). The
"nearest first" balancing runs every 5 s per network, spread out so networks do not all update on
the same tick. To check the cost on your save, enable `show-time-usage` in the debug settings (F4).

## Notes

* Power Overload's high- and low-priority transformers are hidden: they cannot be crafted, and
  saves that had unlocked them lose the recipes. Their priority makes them supply first or last,
  while this mod splits a network's supply among its transformers as if they shared it. Ones
  already built keep working, but their losses are not accurate on networks with mixed priorities.
* Power Overload's transformer data is private, so each transformer's power is read from network
  statistics; when several feed one network the total is split by Power Overload's buffer sizes.
* A wire added or removed inside a network without merging or splitting it is picked up by the
  background pass, so it can take a while on very large bases.
* By default machines count as spread evenly over poles, so a heavy machine cluster costs the same as
  a light one on the same poles. Turn on "weight machines by their live load" to locate them, or put a
  transformer in front of a big remote load to have it measured exactly.
* Not charged: machines powered directly by a generator network (no transformer in between), and
  generators wired into a network that a transformer also feeds.

## Credits and licence

* Built on [Power Overload](https://mods.factorio.com/mod/PowerOverload) by Xorimuth (Tom Burrows),
  which it requires. Parts of this mod are adapted from Power Overload's code, and it uses Power
  Overload's `shared.lua` and settings at runtime.
* MIT licence. LICENCE.txt keeps Power Overload's copyright notice (Copyright (c) 2022 Tom Burrows)
  together with this add-on's (Copyright (c) 2026 Antonio Carnevali).
