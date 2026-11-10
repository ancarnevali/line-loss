# ---
# jupyter:
#   jupytext:
#     text_representation:
#       extension: .py
#       format_name: percent
# ---

# %% [markdown]
# # 5. How many transformers?
#
# Splitting a factory block between more step-down transformers shortens every route on the block's
# wiring, so the **downstream line loss** falls. But every switched-on transformer loses a constant
# **core loss**, whatever its load. Somewhere in between the total is lowest. This notebook looks at
# where that optimum sits for blocks wired with different poles, at different loads and sizes, and
# fed from different poles.
#
# 1. How the mod rates a transformer for core loss
# 2. Blocks wired with small poles, medium poles or substations
# 3. The load: a busy block wants more transformers
# 4. The block's size
# 5. What feeds the block
#
# Inefficiency (1% of what passes through) is the same whatever the number of transformers, so it is
# left out of every comparison.

# %%
import numpy as np
import matplotlib.pyplot as plt

import lineloss_model as m

SPACING = {"small": 7, "medium": 7, "substation": 18}
COUNTS = [1, 2, 4, 8, 16]
BLOCK_POLES = ["small", "medium", "substation"]      # big poles are kept for transmission here
# Power Overload caps a network at its weakest pole's rating, and the block is one network however
# many transformers feed it. That is the most a block of each kind can ever draw.
CAP = {"small": 10e6, "medium": 60e6, "substation": 135e6}
COLOURS = {"small": "#b08968", "medium": "#7f8c8d", "substation": "#5d6d7e", "big": "#2e4053",
           "huge": "#17202a"}


def transformer_loss(dist, poles):
    """Machines spread evenly over the poles: L/(1-L) averaged, back to a share of output."""
    g = np.array([m.loss_ratio(m.route_loss(dist[p])) for p in poles])
    return m.loss_from_ratio(g.mean())


def block(kind, width=140, height=70):
    sp = SPACING[kind]
    nx, ny = int(round(width / sp)) + 1, int(round(height / sp)) + 1
    poles, wires = m.grid_poles("b", 0, 0, nx, ny, sp, kind)
    return poles, wires, nx, ny


def entry_poles(n, nx, ny):
    """West edge middle; both short edges; or spread evenly along the two long edges."""
    if n == 1:
        return [f"b0_{ny // 2}"]
    if n == 2:
        return [f"b0_{ny // 2}", f"b{nx - 1}_{ny // 2}"]
    per_side = n // 2
    cols = [int(round((2 * k + 1) * (nx - 1) / (2 * per_side))) for k in range(per_side)]
    return [f"b{c}_0" for c in cols] + [f"b{c}_{ny - 1}" for c in cols]


_cache = {}


def downstream_ratio(kind, n, width=140, height=70):
    """W lost per W delivered on the block's wiring, n transformers ("nearest first" ownership)."""
    key = (kind, n, width, height)
    if key not in _cache:
        poles, wires, nx, ny = block(kind, width, height)
        names = list(poles)
        entries = entry_poles(n, nx, ny)
        dists = {f"T{i + 1}": m.shortest_distances(poles, wires, e) for i, e in enumerate(entries)}
        own = m.ownership(dists)
        total = 0.0
        for t, d in dists.items():
            mine = [p for p in names if own[p] == t]
            if mine:
                total += len(mine) / len(names) * m.loss_ratio(transformer_loss(d, mine))
        _cache[key] = total
    return _cache[key]


def rating(upstream, downstream):
    """The mod's rule: the weaker side's strongest pole."""
    return min(m.RATINGS[upstream], m.RATINGS[downstream])


def losses(kind, n, load, upstream="big", width=140, height=70):
    line = load * downstream_ratio(kind, n, width, height)
    core = n * rating(upstream, kind) * m.CORE_LOSS
    return line, core


def bar_panel(ax, rows, title):
    xs = np.arange(len(rows))
    ax.bar(xs - 0.2, [r[1] / 1e6 for r in rows], 0.4, label="downstream line loss", color="#7f8c8d")
    ax.bar(xs + 0.2, [r[2] / 1e6 for r in rows], 0.4, label="core loss", color="#1d9e75")
    tot = [(r[1] + r[2]) / 1e6 for r in rows]
    ax.plot(xs, tot, "o-", color="#d85a30", label="total")
    best = int(np.argmin(tot))
    ax.plot(xs[best], tot[best], "*", ms=16, color="#d85a30")
    ax.set_xticks(xs, [str(r[0]) for r in rows])
    ax.set_xlabel("transformers feeding the block")
    ax.set_title(title, fontsize=10)


def best_count(kind, load, upstream="big", width=140, height=70, counts=COUNTS):
    tot = [sum(losses(kind, n, load, upstream, width, height)) for n in counts]
    return counts[int(np.argmin(tot))], min(tot)


# %% [markdown]
# ## 1. How the mod rates a transformer for core loss
#
# Each side of a transformer is rated by the highest-rated pole wired to it, and the transformer by
# the **weaker** side:
#
#     rating = min(strongest pole on the upstream side, strongest pole on the downstream side)
#     core loss = 0.1% × rating, while switched on
#
# A step-down transformer into a medium block is rated 60 MW (60 kW of core loss) whether big or huge
# poles feed it. The table shows the core loss per transformer for every pair of pole types.

# %%
types = ["small", "medium", "substation", "big", "huge"]
table = np.array([[rating(u, d) * m.CORE_LOSS / 1e3 for d in types] for u in types])
fig, ax = plt.subplots(figsize=(6.5, 5))
im = ax.imshow(np.log10(table), cmap="YlGn")
for i in range(len(types)):
    for j in range(len(types)):
        v = table[i, j]
        ax.text(j, i, f"{v:.0f} kW" if v < 1000 else f"{v / 1e3:.0f} MW", ha="center", va="center",
                fontsize=9, color="white" if np.log10(v) > 2.5 else "black")
ax.set_xticks(range(len(types)), types)
ax.set_yticks(range(len(types)), types)
ax.set_xlabel("strongest pole on the downstream side")
ax.set_ylabel("strongest pole on the upstream side")
ax.set_title("Core loss per switched-on transformer")
plt.show()

# %% [markdown]
# Only the diagonal and the cells next to it are expensive: a transformer pays a high core loss only
# when *both* sides are wired with high-rated poles, for example a big-to-big tie or a huge-to-huge
# step. A step-down into a block pays the block's rating.
# AC Q is this realistic? I think the rating should be referred to the higher of the two sides?
# %% [markdown]

# ## 2. Blocks wired with small poles, medium poles or substations
#
# A 140 × 70-tile block drawing 40 MW, fed from a big-pole trunk by 1 to 16 transformers spread along
# its edges. Each transformer feeds the poles nearest to it. The block's own poles set both the
# downstream line loss (their resistance) and the core loss (the weaker side is the block's side).

# %%
fig, axes = plt.subplots(1, 3, figsize=(15, 3.8))
for ax, kind in zip(axes, BLOCK_POLES):
    load = CAP[kind]
    rows = [(n, *losses(kind, n, load)) for n in COUNTS]
    bar_panel(ax, rows, f"{kind}-pole block at its cap, {load / 1e6:.0f} MW\n"
                        f"core loss {rating('big', kind) * m.CORE_LOSS / 1e3:.0f} kW per transformer")
    ax.set_ylabel(f"MW lost delivering {load / 1e6:.0f} MW")
axes[0].legend(fontsize=8)
plt.suptitle("Each block carrying the most Power Overload allows on its poles", fontsize=11)
plt.tight_layout()
plt.show()

for kind in BLOCK_POLES:
    load = CAP[kind]
    n, tot = best_count(kind, load)
    print(f"{kind:>10} block at {load / 1e6:6.0f} MW: best {n:2d} transformers, "
          f"{tot / 1e6:.2f} MW lost ({tot / load * 100:.1f}%)")

# %% [markdown]
# Each block is shown carrying the most its poles allow, which is also where splitting pays off
# most. A small-pole block has by far the highest line loss but the cheapest core loss, 10 kW a
# transformer, so splitting keeps helping; substations have the lowest line loss and the dearest
# core loss, 135 kW, so their optimum comes earliest.

# %% [markdown]
# ### The floor: many transformers on a one-pole network
#
# Push the idea to its limit. A single small pole with 8 MW of machines on it, fed by 1 to 8
# transformers all wired to that one pole. Every route is the length of one wire, so there is almost
# no line loss left to save, and each transformer still charges its 10 kW of core loss.

# %%
rows = []
for n in [1, 2, 4, 8]:
    poles = {"p": (0.0, 0.0, "small")}
    wires = []
    for i in range(n):
        poles[f"T{i + 1}"] = (3 * np.cos(i * 2 * np.pi / n), 3 * np.sin(i * 2 * np.pi / n), "small")
        wires.append((f"T{i + 1}", "p"))
    d = m.shortest_distances(poles, wires, "T1")["p"]
    line = 8e6 * m.loss_ratio(m.route_loss(d))
    core = n * m.RATINGS["small"] * m.CORE_LOSS
    rows.append((n, line, core))

fig, ax = plt.subplots(figsize=(6.5, 3.6))
bar_panel(ax, rows, "One small pole, 8 MW of machines: nothing left to save")
ax.set_ylabel("MW lost delivering 8 MW")
ax.legend(fontsize=8)
plt.tight_layout()
plt.show()
for n, line, core in rows:
    print(f"{n} transformer(s): line {line / 1e3:7.2f} kW + core {core / 1e3:6.0f} kW = {(line + core) / 1e3:6.0f} kW")

# %% [markdown]
# The line loss does not move at all: every transformer is one wire away from the same pole, so a
# second one has no distance to remove. All it adds is its own 10 kW, and the total climbs straight
# from 43 kW to 113 kW. Splitting a block only pays while there is distance left to take out.
# %% [markdown]
# ### The small-pole block on the map

# %%
fig, axes = plt.subplots(1, 3, figsize=(18, 4.2))
for ax, n in zip(axes, [1, 4, 16]):
    poles, wires, nx, ny = block("small")
    entries = entry_poles(n, nx, ny)
    dists = {f"T{i + 1}": m.shortest_distances(poles, wires, e) for i, e in enumerate(entries)}
    own = m.ownership(dists)
    shown = dict(poles)
    for i, e in enumerate(entries):
        x, y, _ = poles[e]
        shown[f"T{i + 1}"] = (x - 6 if n == 1 else x, y if n == 1 else (y - 6 if y == 0 else y + 6), "small")
    line, core = losses("small", n, 40e6)
    m.draw_network(ax, shown, wires + [(f"T{i + 1}", e) for i, e in enumerate(entries)],
                   values={p: m.route_loss(dists[own[p]][p]) * 100 for p in poles}, vmin=0, vmax=20,
                   transformers=list(dists), colorbar_label="route loss (%)",
                   title=f"{n} transformer{'s' if n > 1 else ''}\ndownstream line loss {line / 1e6:.2f} MW, "
                         f"core loss {core / 1e6:.2f} MW")
plt.tight_layout()
plt.show()

# %% [markdown]
# ## 3. The load: a busy block wants more transformers
#
# Core loss is constant, but downstream line loss is proportional to the load. The busier the block,
# the more transformers it is worth splitting it between.

# %%
loads = np.array([2, 5, 10, 20, 40, 80, 135]) * 1e6
fig, axes = plt.subplots(1, 2, figsize=(13, 3.8))
for kind in BLOCK_POLES:
    mine = [L for L in loads if L <= CAP[kind]]      # a block cannot draw more than its poles allow
    best = [best_count(kind, L)[0] for L in mine]
    share = [best_count(kind, L)[1] / L * 100 for L in mine]
    axes[0].plot(np.array(mine) / 1e6, best, "o-", color=COLOURS[kind], label=f"{kind} block")
    axes[1].plot(np.array(mine) / 1e6, share, "o-", color=COLOURS[kind], label=f"{kind} block")
axes[0].set_xscale("log")
axes[0].set_yscale("log", base=2)
axes[0].set_yticks(COUNTS, [str(c) for c in COUNTS])
axes[0].set_xlabel("block load (MW)")
axes[0].set_ylabel("best number of transformers")
axes[0].set_title("Best count grows with the load")
axes[0].legend()
axes[1].set_xscale("log")
axes[1].set_xlabel("block load (MW)")
axes[1].set_ylabel("lost at the best count (% of the load)")
axes[1].set_title("Downstream line loss + core loss at the optimum")
axes[1].legend()
plt.tight_layout()
plt.show()

# %% [markdown]
# A lightly loaded block is best fed by one or two transformers: their core loss would be a large
# share of a small load. A busy block is worth splitting finely.

# %%
fig, axes = plt.subplots(1, 3, figsize=(15, 3.8))
for ax, L in zip(axes, [10e6, 30e6, 60e6]):
    rows = [(n, *losses("medium", n, L)) for n in COUNTS]
    bar_panel(ax, rows, f"the same block drawing {L / 1e6:.0f} MW")
    ax.set_ylabel(f"MW lost delivering {L / 1e6:.0f} MW")
axes[0].legend(fontsize=8)
plt.suptitle("Why the best count moves: the grey bars scale with the load, the green ones do not\n"
             "(one 140 x 70-tile medium block, from a sixth of its 60 MW cap up to the cap)", fontsize=11)
plt.tight_layout()
plt.show()

# %% [markdown]
# At 10 MW a second transformer's core loss costs more than the line loss it saves, so one wins. At
# the block's 60 MW cap the line loss is six times larger while the core loss is unchanged, so
# splitting four ways is clearly worth it. That is the whole mechanism behind the previous figure.
# %% [markdown]
# ## 4. The block's size
#
# Square blocks of medium poles from 35 to 280 tiles a side, all drawing 0.75 kW per square tile, so
# 0.9 MW for the smallest and 58.8 MW for the largest, which is just under the 60 MW a medium-pole
# network may carry. Larger blocks have longer routes and more load, so they want more transformers.
# (The smallest block loses a higher share because one transformer's 60 kW of core loss is a large
# part of its 0.9 MW.)

# %%
sides = [35, 70, 140, 210, 280]
counts = [1, 2, 4, 8, 16, 32]
best_n, tot_share = [], []
for side in sides:
    load = 750 * side * side        # just under the 60 MW cap at 280 tiles a side
    tot = [load * downstream_ratio("medium", n, side, side) + n * rating("big", "medium") * m.CORE_LOSS
           for n in counts]
    best_n.append(counts[int(np.argmin(tot))])
    tot_share.append(min(tot) / load * 100)

fig, ax = plt.subplots(figsize=(7, 3.8))
ax.plot(sides, best_n, "o-", color="#7f8c8d", label="best number of transformers")
ax.set_yscale("log", base=2)
ax.set_yticks(counts, [str(c) for c in counts])
ax.set_xlabel("block side (tiles), medium poles, 0.75 kW per square tile")
ax.set_ylabel("best number of transformers")
ax2 = ax.twinx()
ax2.plot(sides, tot_share, "s--", color="#d85a30", label="lost at the optimum (% of load)")
ax2.set_ylabel("lost at the optimum (% of the load)")
ax.set_title("Bigger blocks want more transformers")
fig.legend(loc="upper left", bbox_to_anchor=(0.12, 0.88), fontsize=8)
plt.show()

# %% [markdown]
# ## 5. What feeds the block
#
# The same medium block, 40 MW, fed from small, medium, substation, big or huge poles upstream. With
# the weaker-side rule, every upstream pole at least as strong as the block's gives the same 60 MW
# rating, so medium, substation, big and huge feeds are identical. Only a small-pole feed lowers
# the rating (to 10 MW), and with it the core loss.

# %%
fig, axes = plt.subplots(1, 5, figsize=(19, 3.8), sharey=True)
for ax, upstream in zip(axes, ["small", "medium", "substation", "big", "huge"]):
    rows = [(n, *losses("medium", n, 40e6, upstream)) for n in COUNTS]
    bar_panel(ax, rows, f"fed from {upstream} poles\nrating min({upstream}, medium) = "
                        f"{rating(upstream, 'medium') / 1e6:.0f} MW")
axes[0].set_ylabel("MW lost delivering 40 MW")
axes[0].legend(fontsize=8)
plt.tight_layout()
plt.show()

# %% [markdown]
# The poles feeding the block do not change the optimum, except a small-pole feed, which lowers the
# rating. That only happens when a small pole is the *strongest* pole on the upstream side, i.e. the
# transformer's input is wired to small poles only; one small pole next to stronger ones does not do
# it. And Power Overload rates a small pole at 10 MW: carrying more overloads it, so a small-pole
# feed can supply at most 10 MW per transformer. For this 40 MW block that means at least 4
# transformers anyway (the 1- and 2-transformer bars of the first panel are not buildable). What feeds the block matters for the **upstream** line loss of the
# transformer instead, the trunk that brings the power, which is the same whatever the number of
# transformers on the block.
#
# **Summary.** The number of transformers worth putting on a block is set by the block's own poles,
# its load and its size: about 4 for a busy medium or substation block of this size, 16 or more for
# a small-pole block, 1 or 2 for a lightly loaded one.

# %%
