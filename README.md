# Line loss

An add-on for [Power Overload](https://mods.factorio.com/mod/PowerOverload) (Factorio 2.1).
Power is lost along the wires between transformers, depending on distance, pole type and load.
Every loss is a real demand on your network, visible in the electric network statistics.

## Requirements and setup

* Factorio 2.1 and Power Overload 2.3.3 or later.
* Line loss locks two Power Overload options:
  * **Transformer efficiency: 1**. Line loss applies transformer efficiency and core loss itself.
  * **When power pole is overloaded: Nothing**. Line loss checks each pole against the local power
    instead (setting "When a pole is overloaded").

## How it works

This mod simulates power transmission losses.

The power grid is divided into two parts, a transmission section and a distribution section, identified by the poles that take part in them. Any pole with a Power Overload rating equal to or greater than the vanilla big electric pole (currently 300 MW) is classified as a transmission pole. A network made only of transmission poles is a transmission network; a network with any distribution pole or generator is a distribution network.

### Transmission networks

Simulated with a DC power flow model, solving the Kirchhoff matrix: power splits over parallel lines by resistance, and each wire loses more the more power it carries.

### Distribution networks

Simulated with a resistance-weighted nearest-source assignment, which is less computationally expensive. Each pole is assigned to its closest source (transformer or generator alike), by computing resistance-weighted distance along copper wires. Each tile of wire loses a fixed share.

* **"Weight machines by their live load" off (default):** the network's load is spread evenly over all poles.
* **On:** each machine weighs on the poles covering it by its live power draw, so power-hungry machines far from transformers contribute more to the line loss. This costs extra script time when a network changes, but is slightly closer to a proper Kirchhoff solve of the network.

### How it's done

* Each transformer pays the losses on the power it supplies; one fed by generators also pays for
  the wires to them.
* Losses are drawn by hidden consumers: **Line loss** and **Transformer losses** (inefficiency
  plus core loss). They appear in the electric network statistics like any other consumer.

Details and worked examples are in **FAQs.txt**.

## Interface

* **Hover** a transformer: power drawn and "Loss upstream" (total upstream loss); optionally
  "Loss downstream" (line loss of the next segment). Coloured green < 10%, yellow < 50%, red.
* **Transformer panel**: upstream, the total loss and the power received; downstream, the total
  loss and the power supplied after all losses. Hovering a total shows its line loss, inefficiency
  and core loss. With the per-player setting "Transformer panel: show detailed info": every loss
  row by row, with tooltips, and "Hover information" checkboxes for that transformer's hover.
* **Line loading** (map view): power on each wire, green to red up to the busiest.
* **Line loading (% of rating)** (map view): power on each wire against its weaker pole's rating,
  yellow above 60%, red above 80%.
* **Line losses** (map view): power lost on each wire, green to red across all wires on the
  surface. Diamonds show each transformer's total upstream loss. Opens the network panel.
* **Networks** (map view): transmission networks in blue; in distribution networks, each wire in
  the colour of the transformer feeding it, grey where several sources meet.
* **Network panel**: the network downstream of the transformer you hover or open: its type, its
  sources (feeding transformers and generators), its consumption (machines, downstream
  transformers, transformer losses, line loss) and the 5 wires losing the most power, each with a
  **Show** button.
* In any view, hovering a transformer shows what feeds it. Power Overload's network colouring is
  hidden while a view is on.

All four shortcuts can be bound to keys.

## Transmission poles

Every pole Power Overload rates like a big electric pole or more (huge poles, fuses, other mods' poles) is a **transmission pole**: no supply area, but transfers power more efficiently.
To power machines, step down to distribution poles through a transformer. You can place transmission poles in a distribution network, but they will have a resistance penalty to avoid exploits.

## Compact substation

You might want to better control what a substation feeds or is fed by. This substation is exactly like a vanilla one, but with a medium pole's supply area.

## Crafting menu

An **Energy** tab (adapted from Energy Category, see credits) holds the energy items in rows by what
they do: steam, electricity, storage, heat, and three rows for power lines: transmission poles,
distribution poles, transformers. With Energy Category installed, its tab is used.

## Settings (map)

| Setting | Default | Effect |
|---|---|---|
| Line losses | on | Turns line losses and their displays on or off |
| Line loss per tile (%) | 0.025 | Loss per tile of resistance-weighted distance; transmission wires lose this at a quarter of their rating, never less than a tenth of it, never more than 95% |
| Mixed wire resistance multiplier | 2 | Resistance of wires where transmission poles are connected to a distribution network; 1 turns it off |
| Weight machines by their live load in distribution networks | off | Each machine weighs on the poles covering it by its live power draw; costs extra script time |
| When a pole is overloaded | Destroy | Destroy, damage or catch fire, checked against the local power |
| Transformer efficiency | 0.99 | Energy out per energy in |
| Transformer core loss (%) | 0.1 | Constant loss of a switched-on transformer, % of its rating; 0 turns it off |

## Settings (per player)

| Setting | Default | Effect |
|---|---|---|
| Transformer panel: show detailed info | off | Every loss row by row |
| Transformer panel: unify power unit | off | Every power figure in the unit of the largest |
| Transformer panel: input − output check | off | Adds input − output next to the total loss |

## Gameplay

* Carry power far on big or huge poles; step down close to the factory.
* Parallel transmission lines share the load and lose less than one busy line.
* Feed large networks from several sides.
* Every transformer in a chain costs inefficiency and core loss: don't stack them without reason.
* Put step-up transformers in the middle of generator fields, and local generation (solar) next to
  hungry machines far from the transformers.
* Use the line losses view and its list of the wires losing most to find the best upgrades.

## Performance

* Losses are recomputed every 5 s by a background job spread over many ticks, so a large base
  causes no spikes. The network data it works on is rebuilt when wires or generators change.
* Wires are read from a cached copy; a background check compares 20 cached poles per tick with the
  game.
* Power is measured once a second; losses follow load changes within a few seconds.
* "Weight machines by their live load" adds an entity search per pole and re-searches when machines
  are built or removed.
* Check the cost on your save with `show-time-usage` (F4 debug settings).

## Notes

* Power Overload's high- and low-priority transformers are hidden, so they don't interfere with how
  this mod assigns generators and consumers to transformers.
* A wire added or removed inside a network is picked up by the background check: a few seconds on a
  5,000-pole base, longer on bigger ones.
* Losses are always paid by a transformer: a network without transformers has no line losses
  (vanilla electricity until transformers are researched), and power from generators that reaches
  machines without passing a transformer is not charged.
* Older saves are upgraded automatically.

## Credits and licence

* Built on [Power Overload](https://mods.factorio.com/mod/PowerOverload) by Xorimuth (Tom Burrows),
  and uses parts of its code.
* The Energy tab is adapted from [Energy Category](https://mods.factorio.com/mod/EnergyCategory) by
  Lumme (MIT), including its tab icon; the idea of moving every pole there from
  [Power poles in energy tab](https://mods.factorio.com/mod/power-poles-in-energy-tab) by Ander_PC_.
* MIT licence (see LICENCE.txt).
