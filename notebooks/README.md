# Line loss: example notebooks

Jupytext "percent" notebooks (`.py` files with `# %%` cells). Open them in Jupyter with the
jupytext extension (`pip install jupytext`), or in VS Code / PyCharm, which read `# %%` cells
directly. They can also run as plain scripts: `python 01_resistance_and_route_loss.py`.

Requirements: Python 3, numpy, matplotlib. Keep `lineloss_model.py` next to the notebooks.

| Notebook | Shows |
|---|---|
| 01_how_the_mod_works | resistance per pole type, route loss and the 95% cap, shortest paths, why the burn is delivered × L/(1−L), why each route is capped and averaged on its own, both FAQ examples with a map and a loss waterfall |
| 02_generation | generators to the step-up transformer: medium vs substation collection, where the transformer connects, splitting a 1 GW plant into subnets (Power Overload limits), gathering subnets on huge poles, a solar field |
| 03_transmission | how far each pole type carries power, one huge line vs four big lines for 1 GW, repeater transformers on very long lines, separate lines vs a trunk with branches |
| 04_end_nodes | inside a factory block, maps to scale: distance, loss and power lost per pole; corner, edge or centre feed; small, medium or substation wiring; a big-pole spur; feeding from two sides; block size; heavy machines far or near |
| 05_how_many_transformers | how the mod rates core loss (weaker side), downstream line loss against core loss by the block's poles, its load, its size, and what feeds it |
| 06_balancing_and_weighting | several sources on one network: what "feed nearest consumers first" changes, a line fed from both ends against exact current division, a steam field where the mod has no choice, pairing two transformers to one field, and what machine weighting changes |

Notebook 1 opens with a glossary. The notebooks use *route loss* for one route, *loss ratio* for
L/(1−L), and *upstream* / *downstream line loss* for a transformer's own figures; map axes are plain
tiles, while every `d` is a resistance-weighted distance.

`lineloss_model.py` is a small teaching re-implementation of the mod's formulas at default settings.
It skips scheduling, smoothing and the sparse kernel, so a few results (notably the steam-field
pairing in notebook 4) differ slightly from the mod's in-game values.
