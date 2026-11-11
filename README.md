# Line loss

An add-on for [Power Overload](https://mods.factorio.com/mod/PowerOverload) (Factorio 2.1).
Power is lost along the wires between transformers: the farther it travels and the thinner the
poles, the more is lost. Transformers also lose a little in conversion, plus a small core loss.
Every loss is a real demand on your network, visible in the electric network statistics.

## Requirements and setup

* Factorio 2.1 and Power Overload 2.3.3 or later.
* Set Power Overload's **Transformer efficiency** to **1 (100%)**: this mod charges transformer
  inefficiency itself. Otherwise its own efficiency setting is ignored and a warning is shown.

## How it works, in short

* Each pole type has a **line resistance** (in its tooltip): small poles about 5.5× a big pole,
  huge poles about 0.3×.
* A **segment** is the wires between two transformers, or between the generators and a
  transformer. Each route through a segment loses 0.025% per tile of resistance-weighted distance,
  capped at 95%. A transformer is charged the sum over the routes of its next segment.
* Transformers fed directly by generators also pay for the wires to them; far generators cost more.
* Losses are drawn by hidden consumers: **Line loss** and **Transf. ineff.** (inefficiency plus
  core loss).

Details and worked examples are in **FAQs.txt**.

## Interface

* **Hover** a transformer: power drawn and "Loss upstream" (total upstream loss); optionally
  "Loss downstream" (line loss of the next segment). Coloured green < 10%, yellow < 50%, red.
* **Transformer panel**: a line saying whether "feed nearest consumers first" is on, what powers
  this transformer (how many transformers or generators) and how far away. Upstream: power
  generated for this transformer, minus lines, inefficiency and core loss on the way, equals power
  received; total loss; line loss of the last segment. Downstream, laid out the same: input,
  minus next-segment line loss, inefficiency and core loss, equals output; total loss. Every row
  reads "power (percentage)"; tooltips explain each one with the live figures.
  "Hover information" checkboxes choose what that transformer's hover shows.
* **Grid diagram** (shortcut, map view): one line per route between transformers, width = power,
  colour = loss; a diamond on each receiving transformer, coloured by its total upstream loss. Idle routes are hidden unless "Grid
  diagram: show idle routes" is on.
* **Grid power panel** (with the grid diagram, draggable): power generated, delivered and lost over
  the last 5 s, and the 5 routes losing the most, each with a **Show** button.
* **Line-loss map** (shortcut, map view): a dot per pole, colour = line loss reaching it, size =
  power lost on its machine load. Big red dots are where an upgrade saves the most.

* **Feed paths** (shortcut, map view): for the transformer you last hovered or opened, the
  shortest resistance-weighted paths from its sources, coloured by the line loss built up on the
  way, wider for a bigger share. Power Overload's network colouring is hidden while it is on.

All three shortcuts can be bound to keys.

## Big transmission pole

A big electric pole with no supply area: same reach, recipe, rating and line resistance, but it
powers nothing around it. Use it for long lines past factories. Unlocked with the big pole.

## Settings (map)

| Setting | Default | Effect |
|---|---|---|
| Line losses | on | Turns line losses and their displays on or off |
| Line loss per tile (%) | 0.025 | Loss per tile of resistance-weighted distance |
| Line losses: feed nearest consumers first | on | Each transformer's power goes mostly to the consumers nearest to it |
| Line losses: weight machines by their live load | off | Locates machines per pole and weights them by what they draw; costs extra script time |
| Transformer efficiency | 0.99 | Energy out per energy in |
| Transformer core loss (%) | 0.1 | Constant loss of a switched-on transformer, % of its rating; 0 turns it off |

## Settings (per player)

| Setting | Default | Effect |
|---|---|---|
| Grid diagram: show idle routes | off | Also draws routes carrying no power, in grey |
| Transformer panel: one unit for all power figures | off | All power figures in the unit of the largest |
| Transformer panel: show input - output next to total loss | off | For checking that it equals the sum of the losses |

## Gameplay

* Carry power far on big or huge poles; step down close to the factory.
* Feed large networks from several sides.
* Every transformer in a chain costs inefficiency and core loss: don't stack them without reason.
* Use the line-loss map and the worst-routes list to find the best upgrades.

## Performance

* Searches run one transformer at a time, only when its network changes (up to 100 poles per tick),
  plus a slow background pass (10 poles per tick).
* Power is measured once a second; losses follow load changes within a few seconds.
* "Weight machines by their live load" adds an entity search per pole and re-searches when machines
  are built or removed.
* Check the cost on your save with `show-time-usage` (F4 debug settings).

## Notes

* Power Overload's high- and low-priority transformers are hidden, so they don't interfere with how
  this mod assigns generators and consumers to transformers.
* A wire added inside a network is picked up by the background pass, which can take a while on
  large bases.
* By default machine load counts as spread evenly over the poles; turn on machine weighting to
  locate it.
* Not charged: machines on a generator network with no transformer in between, and generators wired
  into a network a transformer also feeds.
* Older saves are upgraded automatically.

## Credits and licence

* Built on [Power Overload](https://mods.factorio.com/mod/PowerOverload) by Xorimuth (Tom Burrows),
  and uses parts of its code.
* MIT licence (see LICENCE.txt).
