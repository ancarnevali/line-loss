# Line loss: example notebooks

Jupytext "percent" notebooks (`.py` files with `# %%` cells). Open them in Jupyter with the
jupytext extension (`pip install jupytext`), or in VS Code / PyCharm, which read `# %%` cells
directly. They can also run as plain scripts: `python 01_resistance_and_route_loss.py`.

Requirements: Python 3, numpy, matplotlib. Keep `lineloss_model.py` next to the notebooks.

| Notebook | Shows |
|---|---|
| 01_resistance_and_route_loss | resistance per pole type, wire cost, shortest paths, route loss and the 95% cap |
| 02_transformer_chain | where each loss is burned, why the burn settles in one step, both FAQ examples |
| 03_several_feeders | proportional vs "nearest first" balancing, feeding a line from both ends, per-route cap |
| 04_generators_and_machine_weighting | generator networks, two transformers on one steam field, machine weighting, power lost per pole |

`lineloss_model.py` is a small teaching re-implementation of the mod's formulas at default settings.
It skips scheduling, smoothing and the sparse kernel, so a few results (notably the steam-field
pairing in notebook 4) differ slightly from the mod's in-game values.
