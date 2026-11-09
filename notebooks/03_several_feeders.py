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
# # 3. Several transformers feeding one network
#
# When several transformers (sources) feed the same network, the mod has to decide which consumers
# each one pays for.
#
# * **Off** ("feed nearest consumers first" disabled): every source feeds every consumer in the same
#   proportions, `f_ik = P_i · Q_k / ΣQ`.
# * **On** (default): flows are balanced so every source delivers its measured power and every
#   consumer receives its measured draw, each pairing pulled by `1 / d` (current divides inversely
#   with resistance): `f_ik = a_i · K_ik · b_k`.
#
# Each source then pays the flow-weighted average of its capped route losses.

# %%
import matplotlib.pyplot as plt
import numpy as np

import lineloss_model as m

# %% [markdown]
# ## The G/S example from the discussion
#
# G1–G3 are the transformers feeding the network; S1–S3 downstream transformers; the last column is
# the network's machines (at each source's mean pole distance).

# %%
d = np.array([[10, 120, 250, 60],
              [130, 15, 140, 55],
              [240, 110, 20, 70]], float)
P = np.array([40, 30, 10.0])            # MW delivered by G1..G3
Q = np.array([25, 20, 15, 20.0])        # MW drawn by S1, S2, S3, machines

flows_on = m.sinkhorn(1 / np.maximum(d, 1), P, Q)
flows_off = np.outer(P, Q / Q.sum())

np.set_printoptions(precision=1, suppress=True)
print("Flows, nearest first ON (MW)\n", flows_on)
print("\nFlows, OFF: proportional (MW)\n", flows_off)
for name, f in [("on", flows_on), ("off", flows_off)]:
    print(f"\nloss per source ({name}):", np.round(m.weighted_route_loss(f, d) * 100, 2), "%")

# %%
fig, axes = plt.subplots(1, 2, figsize=(10, 3.6), sharey=True)
labels = ["S1", "S2", "S3", "machines"]
for ax, f, title in [(axes[0], flows_on, "nearest first on"), (axes[1], flows_off, "off (proportional)")]:
    im = ax.imshow(f, cmap="Oranges")
    ax.set_xticks(range(4), labels)
    ax.set_yticks(range(3), ["G1", "G2", "G3"])
    for i in range(3):
        for k in range(4):
            ax.text(k, i, f"{f[i, k]:.1f}", ha="center", va="center", fontsize=9)
    ax.set_title(title)
plt.suptitle("Who feeds whom (MW)")
plt.show()

# %% [markdown]
# With the option on, each G mostly feeds the S next to it. S3 still gets power from far-away G1 and
# G2, because its nearest source G3 only has 10 MW: it is a preference, not a greedy assignment.

# %% [markdown]
# ## Feeding a line of machines from both ends
#
# 20 MW of machines spread along 21 big poles (30 tiles apart). With one feeder at the west end, its
# machines' loss is the average over all poles. Add a feeder at the east end: each pole belongs to
# its electrically nearest feeder, and the two halves are balanced by `1/d` per pole. Real current
# division in a line fed from both ends gives each load the share `d_other / (d_A + d_B)` from each
# end.

# %%
x = 30 * np.arange(1, 22, dtype=float)       # pole positions
L_end = 660.0                                 # second feeder at x = 660
one_feeder = np.mean([m.route_loss(xi) for xi in x])

# Current division per pole (exact for a linear loss model)
share_A = (L_end - x) / L_end
exact = np.mean(share_A * x + (1 - share_A) * (L_end - x))

# The mod: each feeder's own poles form a region, pulled by the mean of 1/d over the region
own_A = x <= L_end / 2
regions = [own_A, ~own_A]
K = np.array([[np.mean(1 / np.maximum(np.abs(src - x[r]), 1)) for r in regions] for src in (0.0, L_end)])
D = np.array([[np.mean(np.abs(src - x[r])) for r in regions] for src in (0.0, L_end)])
demand = np.array([r.sum() for r in regions], float)
f = m.sinkhorn(K, [10, 10], demand)
mod_d = (f * D).sum() / f.sum()

print(f"one feeder:                  mean distance {np.mean(x):6.1f}  loss {one_feeder * 100:.2f}%")
print(f"two feeders, current division: mean distance {exact:6.1f}  loss {m.route_loss(exact) * 100:.2f}%")
print(f"two feeders, the mod:          mean distance {mod_d:6.1f}  loss {m.route_loss(mod_d) * 100:.2f}%")

# %% [markdown]
# The mod lands within a few percent of exact current division: feeding from both ends cuts the
# machines' line loss by about a third, not by half, because current from each end still reaches
# loads on the far side.

# %% [markdown]
# ## Why the cap is applied per route
#
# One source with two consumers drawing the same power, one 100 tiles away and one 10,000 tiles away.

# %%
d2 = np.array([[100.0, 10000.0]])
f2 = np.array([[1.0, 1.0]])
per_route = m.weighted_route_loss(f2, d2)[0]
averaged_first = m.route_loss((f2 * d2).sum() / f2.sum())
print(f"cap per route, then average: {per_route * 100:.2f}%")
print(f"average distance, then cap:  {averaged_first * 100:.2f}%")

# %% [markdown]
# Capping each route separately keeps the short route at its own 2.5%; averaging first would charge the
# whole source the 95% cap.
