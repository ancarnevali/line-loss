# Line loss: example notebooks (0.2.0)

Executed Jupyter notebooks (`.ipynb`) with their figures; `gallery/` holds figures for the mod page.
Requirements: Python 3, numpy, matplotlib. Keep `lineloss_model.py` next to them.

| Notebook | Shows |
|---|---|
| 01_transmission | Kirchhoff flows and I²R losses on transmission poles: the loss rule (gallery figures), two parallel lines of different pole types, a bottleneck and a bypass (testbench `/ll-bottleneck`), a meshed grid with three consumers, one stepping down to a medium-pole block (testbench `/ll-flows`) |
| 02_distribution | nearest source with spillover and linear losses on medium, small, substation and compact substation poles: one block fed at a corner or the centre, one block fed by two transformers (equal and unequal deliveries), a downstream transformer at a block's far side, mixed poles, generators (a steam field stepped up at its end or middle, solar inside a block) |

`lineloss_model.py` mirrors the mod's `scripts/kirchhoff.lua` at default settings. On the testbench
layouts `/ll-flows` and `/ll-bottleneck` it gives the mod's flows and losses to four decimals, and
it matches the mod's tests on generator networks and on a block fed from both ends. Not modelled:
machine weighting, Power Overload's overload checks, scheduling and smoothing.
