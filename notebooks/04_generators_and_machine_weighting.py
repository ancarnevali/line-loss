# ---
# jupyter:
#   jupytext:
#     formats: py:percent
#   kernelspec:
#     display_name: Python 3
#     language: python
#     name: python3
# ---

# %% [markdown]
# # 4. Generator networks, machine weighting and power lost per pole
#
# * **Generator networks**: when no transformer feeds a transformer's upstream network, the wires
#   between the generators and the transformer lose power too. Each pole is weighted by the rated
#   output of the generators in its supply area.
# * **Several transformers on one generator network**: generators are paired with transformers by
#   the same balancing as "feed nearest consumers first".
# * **Machine weighting** (opt-in): each pole is weighted by the machines in its supply area and what
#   each machine type draws right now, instead of counting machine load as spread evenly.
# * **Power lost per pole** (map view): `load × L / (1 − L)` at each pole.

# %%
import matplotlib.pyplot as plt
import numpy as np

import lineloss_model as m

# %% [markdown]
# ## A steam field: far engines cost more
#
# 10 big poles run out from a transformer's input, 30 tiles apart; steam engines sit only by the 5
# farthest poles.

# %%
pole_d = 30 * np.arange(1, 11, dtype=float)
engines = np.array([0, 0, 0, 0, 0, 1, 1, 1, 1, 1], float)     # rated output per pole (equal engines)
gen_loss = (engines * np.vectorize(m.route_loss)(pole_d)).sum() / engines.sum()
draw = 10.21e6
print(f"generation-weighted distance {(engines * pole_d).sum() / engines.sum():.0f} tiles, "
      f"loss {gen_loss * 100:.2f}%, burned {draw * gen_loss / (1 - gen_loss) / 1e6:.3f} MW for a {draw / 1e6:.2f} MW draw")

# %% [markdown]
# ## Two transformers drawing from one steam field
#
# 11 engines along 300 tiles of big poles; transformer A draws at the west end, B at the east end,
# 10 MW each. Without pairing, both pay the field's overall average. With pairing, each engine belongs
# to its nearest transformer and the two groups are balanced by `1/d`.

# %%
x = 30 * np.arange(0, 11, dtype=float)
xa, xb = -30.0, 330.0
d_a, d_b = x - xa, xb - x
avg_a = np.mean(np.vectorize(m.route_loss)(d_a))
own_a = d_a <= d_b
groups = [own_a, ~own_a]
K = np.array([[np.mean(1 / np.maximum(dd[g], 1)) for g in groups] for dd in (d_a, d_b)]).T   # groups x transformers
L = np.array([[np.mean(np.vectorize(m.route_loss)(dd[g])) for g in groups] for dd in (d_a, d_b)]).T
supply = np.array([g.sum() for g in groups], float)
f = m.sinkhorn(K, supply, [10, 10])
paired = (f * L).sum(axis=0) / f.sum(axis=0)
print(f"A: average over all engines {avg_a * 100:.2f}%   paired {paired[0] * 100:.2f}%")
print(f"B: paired {paired[1] * 100:.2f}%")

# %% [markdown]
# ## Machine weighting: a power-hungry machine at the end of a line
#
# 21 big poles from a transformer (30 to 630 tiles); a lamp at each of the first 20 poles (10 MW in
# total) and one 100 MW machine at the last pole.

# %%
x = 30 * np.arange(1, 22, dtype=float)
loss = np.vectorize(m.route_loss)(x)
even = loss.mean()
load_running = np.r_[np.full(20, 10e6 / 20), 100e6]
load_idle = np.r_[np.full(20, 10e6 / 20), 0.0]
weighted = (load_running * loss).sum() / load_running.sum()
weighted_idle = (load_idle * loss).sum() / load_idle.sum()
print(f"machines spread evenly (option off): {even * 100:.2f}%")
print(f"weighted, big machine running:       {weighted * 100:.2f}%")
print(f"weighted, big machine idle:          {weighted_idle * 100:.2f}%")

# %% [markdown]
# ## Power lost per pole
#
# What the "Power lost per pole" map view draws for the same line: `load × L / (1 − L)` at each pole,
# with machine weighting on (left) and off (right, machine load spread evenly).

# %%
lost_on = load_running * loss / (1 - loss)
lost_off = np.full(21, load_running.sum() / 21) * loss / (1 - loss)
fig, axes = plt.subplots(1, 2, figsize=(11, 3.4), sharey=True)
for ax, lost, title in [(axes[0], lost_on, "weighting on"), (axes[1], lost_off, "weighting off")]:
    ax.scatter(x, np.zeros_like(x), s=np.clip(lost / 2e4, 8, 1500), c=np.log10(np.maximum(lost, 1e3)),
               cmap="autumn_r", vmin=3, vmax=7.5, edgecolor="k", linewidth=0.3)
    ax.set_title(f"{title}: total {lost.sum() / 1e6:.1f} MW lost")
    ax.set_xlabel("distance from the transformer (tiles)")
    ax.set_yticks([])
plt.suptitle("Power lost per pole (dot size and colour)")
plt.show()

# %% [markdown]
# With weighting on, nearly all the loss is the big machine's pole: that is where a second
# transformer, or a big-pole trunk, pays off. With weighting off, the loss simply grows with
# distance along the line.
