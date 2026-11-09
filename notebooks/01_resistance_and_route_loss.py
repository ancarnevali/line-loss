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
# # 1. Resistance, distance and route loss
#
# How the Line loss mod turns poles and wires into a loss percentage:
#
# 1. each pole type gets a **resistance per tile** from its Power Overload rating;
# 2. each wire costs its length times the average resistance of its two poles;
# 3. a transformer's distance to any pole is the **shortest resistance-weighted path** along the wires;
# 4. a route loses `0.025% × distance`, **capped at 95% per route**.

# %%
import math

import matplotlib.pyplot as plt
import numpy as np

import lineloss_model as m

# %% [markdown]
# ## Resistance per pole type
#
# `r = sqrt(P_big / P_pole)`: a pole rated for 30 times less power than a big pole has about 5.5 times
# its resistance per tile.

# %%
for pole in ["huge", "big", "substation", "medium", "small"]:
    print(f"{pole:>10}: rating {m.RATINGS[pole] / 1e6:>6.0f} MW   resistance {m.resistance(pole):.2f}")

# %% [markdown]
# ## The same 100 tiles on different poles
#
# Distance is measured in tiles of big-pole wire, so the same physical length costs very different
# amounts depending on the poles carrying it.

# %%
for pole in ["huge", "big", "medium", "small"]:
    d = 100 * m.resistance(pole)
    print(f"100 tiles of {pole:>6} poles: distance {d:6.1f}  ->  loss {m.route_loss(d) * 100:5.2f}%")

# %% [markdown]
# ## Loss versus physical length, with the 95% cap
#
# Every route is capped on its own: at least 5% of the power on any route arrives.

# %%
length = np.linspace(0, 8000, 400)
fig, ax = plt.subplots(figsize=(8, 4))
for pole in ["huge", "big", "medium", "small"]:
    ax.plot(length, [m.route_loss(L * m.resistance(pole)) * 100 for L in length], label=pole)
ax.axhline(95, color="grey", ls="--", lw=0.8)
ax.set_xlabel("physical length of the route (tiles)")
ax.set_ylabel("route loss (%)")
ax.set_title("Route loss by pole type (default 0.025% per tile, cap 95%)")
ax.legend()
plt.show()

# %% [markdown]
# ## Shortest path over a small grid
#
# A transformer T feeds a big-pole trunk, which splits into a medium-pole spur and a small-pole
# spur. There is also a shortcut of small poles. The search always takes the cheapest path, which is
# not necessarily the shortest in tiles.

# %%
poles = {
    "T":  (0, 0, "big"),     # the transformer's output pole (counts as resistance 1)
    "B1": (30, 0, "big"),
    "B2": (60, 0, "big"),
    "B3": (90, 0, "big"),
    "M1": (90, 9, "medium"),
    "M2": (90, 18, "medium"),
    "S1": (30, 7, "small"),
    "S2": (37, 14, "small"),
    "S3": (44, 18, "small"),
}
wires = [("T", "B1"), ("B1", "B2"), ("B2", "B3"), ("B3", "M1"), ("M1", "M2"),
         ("B1", "S1"), ("S1", "S2"), ("S2", "S3"), ("S3", "M2")]
dist = m.shortest_distances(poles, wires, "T")

fig, ax = plt.subplots(figsize=(8, 3.6))
for a, b in wires:
    (xa, ya, _), (xb, yb, _) = poles[a], poles[b]
    ax.plot([xa, xb], [ya, yb], color="#999", lw=1.5, zorder=1)
colours = {"big": "#1f77b4", "medium": "#2ca02c", "small": "#d62728"}
for name, (x, y, t) in poles.items():
    ax.scatter(x, y, s=120, color=colours[t], zorder=2)
    ax.annotate(f"{name}\nd={dist[name]:.0f}\n{m.route_loss(dist[name]) * 100:.2f}%",
                (x, y), textcoords="offset points", xytext=(0, 10), ha="center", fontsize=8)
ax.set_title("Resistance-weighted distance and route loss from T (blue big, green medium, red small)")
ax.set_aspect("equal")
ax.axis("off")
plt.show()

# %% [markdown]
# M2 is 18 tiles from S3 over small poles but reached more cheaply through the big trunk and two
# medium wires: the search picks that route, so its loss stays low.
