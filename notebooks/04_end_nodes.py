# ---
# jupyter:
#   jupytext:
#     text_representation:
#       extension: .py
#       format_name: percent
# ---

# %% [markdown]
# # 4. End nodes: inside the factory block
#
# The last stretch, from a step-down transformer to the machines, is usually wired with medium or
# small poles, so it is where resistance is highest and where layout choices matter most. All maps are
# to scale in tiles; wires are coloured by pole type, transformers are green squares, and distances are
# resistance-weighted (tiles of big-pole wire), as the mod measures them.
#
# 1. A factory block: distance, loss and power lost at every pole
# 2. Where the transformer connects: corner, edge or centre
# 3. Which poles to wire the block with: small, medium or substations
# 4. One extra wire: a big-pole spur through the block
# 5. Feeding the block from two sides
# 6. How many transformers per block: downstream line loss against core loss
# 7. How big a block one transformer should feed
# 8. Where the load sits: a hungry corner (machine weighting)

# %%
import numpy as np
import matplotlib.pyplot as plt

import lineloss_model as m


def losses_from(dist):
    return {p: m.route_loss(d) for p, d in dist.items()}


def transformer_loss(dist, poles, weights=None):
    """Machines spread over the poles (or weighted): L/(1-L) averaged, back to a share of output."""
    ps = [p for p in poles if p in dist]
    w = np.array([1.0 if weights is None else weights.get(p, 0.0) for p in ps])
    g = np.array([m.loss_ratio(m.route_loss(dist[p])) for p in ps])
    return m.loss_from_ratio((w * g).sum() / w.sum())


def block_of(kind, width=70, height=42):
    """A block of `kind` poles covering about width x height tiles, spaced at their wire reach."""
    spacing = {"small": 7, "medium": 7, "substation": 18}[kind]
    nx, ny = int(round(width / spacing)) + 1, int(round(height / spacing)) + 1
    return m.grid_poles("b", 7, 0, nx, ny, spacing, kind), spacing, nx, ny


# %% [markdown]
# ## 1. A factory block: distance, loss and power lost at every pole
#
# A transformer T at the left edge feeds a 10 × 7 block of medium poles, 7 tiles apart. The search
# runs from T's output pole along the wires; each medium-pole wire of 7 tiles costs
# 7 × √5 = 15.7 tiles. The far corners are 13 wires away: about 203 tiles, 5.1%.

# %%
poles, wires = m.grid_poles("b", 7, 0, 10, 7, 7, "medium")
poles["T"] = (0, 21, "medium")
wires.append(("T", "b0_3"))
dist = m.shortest_distances(poles, wires, "T")
loss = losses_from(dist)
block = [p for p in poles if p != "T"]

total_load = 20e6                      # 20 MW of machines, spread evenly over the poles
per_pole = total_load / len(block)
lost = {p: per_pole * m.loss_ratio(loss[p]) for p in block}

fig, axes = plt.subplots(1, 3, figsize=(16, 4.4))
m.draw_network(axes[0], poles, wires, values=dist, cmap="viridis", transformers=["T"],
               labels={p: f"{dist[p]:.0f}" for p in block[::3]},
               title="Resistance-weighted distance (tiles)", colorbar_label="resistance-weighted distance (tiles)")
m.draw_network(axes[1], poles, wires, values={p: loss[p] * 100 for p in block}, transformers=["T"],
               vmin=0, vmax=8, title="Route loss L at each pole (%)", colorbar_label="route loss (%)")
m.draw_network(axes[2], poles, wires, values={p: lost[p] / 1e3 for p in block}, transformers=["T"],
               sizes={p: 20 + lost[p] / 300 for p in block}, cmap="Oranges",
               title="Power lost on the way to each pole (kW)", colorbar_label="power lost (kW)")
plt.tight_layout()
plt.show()

L_T = transformer_loss(dist, block)
print(f"the transformer's downstream line loss: {L_T * 100:.2f}%  ->  loses {total_load * m.loss_ratio(L_T) / 1e6:.3f} MW "
      f"to deliver {total_load / 1e6:.0f} MW")
print(f"(sum of the per-pole losses on the right: {sum(lost.values()) / 1e6:.3f} MW)")
# %% [markdown]
# The distance grows in diamonds around the entry point (wires only run along the grid), and the
# power lost per pole grows with it: the far third of the block costs more than the near half.
# The total equals the sum of the per-pole losses, which is what averaging L / (1 − L) guarantees.
#
# On a grid a pole's distance can only be T's link plus a whole number of 7-tile medium wires
# (15.65 tiles each), so the histogram has one bar per number of wires: it rises while each step
# reaches more poles and falls once the far corners are reached.

# %%
fig, ax = plt.subplots(figsize=(7, 3.4))
ds = np.array([dist[p] for p in block])
levels, counts = np.unique(np.round(ds, 1), return_counts=True)   # one bar per number of wires from T
ax.bar(levels, counts, width=10, color="#7f8c8d", edgecolor="white")
ax.axvline(ds.mean(), color="#d85a30", lw=2, label=f"mean distance {ds.mean():.0f} tiles")
ax.yaxis.set_major_locator(plt.MaxNLocator(integer=True))
ax.set_xlabel("resistance-weighted distance from the transformer (tiles)")
ax.set_ylabel("poles")
ax.set_title("How far the block's poles are from the transformer")
ax.legend()
plt.show()

# %% [markdown]
# ## 2. Where the transformer connects: corner, edge or centre
#
# The same 10 × 7 block, with the transformer wired to a corner pole, to the middle of the short edge
# (section 1), or to the centre of the block. The distance to the far poles is what changes.

# %%
fig, axes = plt.subplots(1, 3, figsize=(16, 4.2))
entry_results = {}
for ax, (name, pole, pos) in zip(axes, [("corner", "b0_0", (0, -7)), ("edge", "b0_3", (0, 21)),
                                         ("centre", "b5_3", (42, 21))]):
    poles, wires = m.grid_poles("b", 7, 0, 10, 7, 7, "medium")
    poles["T"] = (pos[0], pos[1], "medium")
    wires.append(("T", pole))
    dist = m.shortest_distances(poles, wires, "T")
    block = [p for p in poles if p != "T"]
    entry_results[name] = transformer_loss(dist, block)
    m.draw_network(ax, poles, wires, values={p: m.route_loss(dist[p]) * 100 for p in block},
                   vmin=0, vmax=8, transformers=["T"], colorbar_label="route loss (%)",
                   title=f"{name}: max d {max(dist[p] for p in block):.0f}, "
                         f"downstream line loss {entry_results[name] * 100:.2f}%")
plt.tight_layout()
plt.show()

# %% [markdown]
# Feeding from the centre roughly halves the loss of a corner feed: every pole is at most half the
# block away. A transformer placed in the middle of the block, or a big-pole spur to its middle
# (section 4), does the same.

# %% [markdown]
# ## 3. Which poles to wire the block with: small, medium or substations
#
# A 70 × 42-tile block wired with small poles (7 tiles apart), medium poles (7) or substations (18).
# Substations have more than twice the medium pole's rating, so a lower resistance (1.49 against
# 2.24), and they reach farther, so fewer wires sit between the transformer and the far corner.

# %%
fig, axes = plt.subplots(1, 3, figsize=(16, 4.2))
type_results = {}
for ax, kind in zip(axes, ["small", "medium", "substation"]):
    (poles, wires), spacing, nx, ny = block_of(kind)
    mid = f"b0_{ny // 2}"
    poles["T"] = (0, poles[mid][1], kind)
    wires.append(("T", mid))
    dist = m.shortest_distances(poles, wires, "T")
    block = [p for p in poles if p != "T"]
    type_results[kind] = transformer_loss(dist, block)
    m.draw_network(ax, poles, wires, values={p: m.route_loss(dist[p]) * 100 for p in block},
                   vmin=0, vmax=10, transformers=["T"], colorbar_label="route loss (%)",
                   title=f"{kind}: {len(block)} poles, downstream line loss {type_results[kind] * 100:.2f}%")
plt.tight_layout()
plt.show()

# %% [markdown]
# Small poles cost about 2.5 times a medium block, and substations about a third less than medium
# poles. The resistance-weighted distance depends on the path's length in tiles, so their longer
# reach does not shorten it by itself; their lower resistance does (1.49 against 2.24 per tile).

# %% [markdown]
# ## 4. One extra wire: a big-pole spur through the block
#
# Back to the block of section 1. A row of big poles is added through its middle, 30 tiles apart,
# wired to the medium poles under them. Big-pole wires cost 1 per tile instead of 2.24, so the far
# columns move much closer.

# %%
poles, wires = m.grid_poles("b", 7, 0, 10, 7, 7, "medium")
poles["T"] = (0, 21, "medium")
wires.append(("T", "b0_3"))
before = m.shortest_distances(poles, wires, "T")

poles2, wires2 = dict(poles), list(wires)
spur = {"s0": (7, 24.5), "s1": (35, 24.5), "s2": (63, 24.5)}
for name, (x, y) in spur.items():
    poles2[name] = (x, y, "big")
wires2 += [("T", "s0"), ("s0", "s1"), ("s1", "s2"),
           ("s0", "b0_3"), ("s1", "b4_3"), ("s2", "b8_3")]
after = m.shortest_distances(poles2, wires2, "T")
block = [p for p in poles if p != "T"]
saved = {p: before[p] - after[p] for p in block}

fig, axes = plt.subplots(1, 2, figsize=(14, 4.4))
m.draw_network(axes[0], poles2, wires2, values={p: after[p] for p in poles2}, cmap="viridis",
               vmin=0, vmax=max(before.values()), transformers=["T"],
               labels={p: f"{after[p]:.0f}" for p in block[::3]},
               title="Distance with the spur (tiles)", colorbar_label="resistance-weighted distance (tiles)")
m.draw_network(axes[1], poles2, wires2, values={p: saved.get(p, 0) for p in poles2}, cmap="Greens",
               transformers=["T"], title="Distance saved by the spur (tiles)", colorbar_label="distance saved (tiles)")
plt.tight_layout()
plt.show()
print(f"downstream line loss: {transformer_loss(before, block) * 100:.2f}% without the spur, "
      f"{transformer_loss(after, block) * 100:.2f}% with it")
#AC let's keep this in mind for balancing. it seems like a potential exploit to me, but I can see its physical meaning
# %% [markdown]
# Three big poles and six wires cut the block's loss by about a quarter, and the far columns save up
# to 65 tiles: the search always takes the cheapest path, so a low-resistance spur pulls every pole
# near it closer to T. (A second parallel path does not lower resistance further: only the shortest
# path counts.)

# %% [markdown]
# ## 5. Feeding the block from two sides
#
# The block of section 1 with a second transformer T2 at the right edge. Each pole belongs to the
# transformer with the shorter distance ("nearest first", on by default); colours show the owner,
# labels the distance to it.

# %%
poles, wires = m.grid_poles("b", 7, 0, 10, 7, 7, "medium")
poles["T1"] = (0, 21, "medium")
poles["T2"] = (77, 21, "medium")
wires += [("T1", "b0_3"), ("T2", "b9_3")]
block = [p for p in poles if p.startswith("b")]
d1 = m.shortest_distances(poles, wires, "T1")
d2 = m.shortest_distances(poles, wires, "T2")
owner = m.ownership({"T1": d1, "T2": d2})
d_own = {p: min(d1[p], d2[p]) for p in block}

fig, axes = plt.subplots(1, 2, figsize=(14, 4.4))
m.draw_network(axes[0], poles, wires, transformers=["T1", "T2"],
               pole_colours={p: "#85b7eb" if owner[p] == "T1" else "#f0997b" for p in block},
               labels={p: f"{d_own[p]:.0f}" for p in block[::3]},
               title="Owner of each pole (blue T1, orange T2) and distance to it")
m.draw_network(axes[1], poles, wires, values={p: m.route_loss(d_own[p]) * 100 for p in block},
               vmin=0, vmax=8, transformers=["T1", "T2"], title="Route loss from the owner (%)",
               colorbar_label="route loss (%)")
plt.tight_layout()
plt.show()

one = transformer_loss(d1, block)
mine = [p for p in block if owner[p] == "T1"]
two = transformer_loss(d1, mine)
print(f"one transformer: {one * 100:.2f}%.   Two feeders: each pays {two * 100:.2f}% on its half.")

# %% [markdown]
# ### One feeder or two, side by side

# %%
poles1, wires1 = m.grid_poles("b", 7, 0, 10, 7, 7, "medium")
poles1["T1"] = (0, 21, "medium")
wires1 = wires1 + [("T1", "b0_3")]
d_one = m.shortest_distances(poles1, wires1, "T1")
LOAD = 20e6

fig, axes = plt.subplots(1, 3, figsize=(17, 4.2), gridspec_kw={"width_ratios": [1.2, 1.2, 0.8]})
m.draw_network(axes[0], poles1, wires1, values={p: m.route_loss(d_one[p]) * 100 for p in block},
               vmin=0, vmax=6, transformers=["T1"], colorbar_label="route loss (%)",
               title=f"One transformer: {one * 100:.2f}% downstream line loss")
m.draw_network(axes[1], poles, wires, values={p: m.route_loss(d_own[p]) * 100 for p in block},
               vmin=0, vmax=6, transformers=["T1", "T2"], colorbar_label="route loss (%)",
               title=f"Two, one at each end: {two * 100:.2f}% each")
lost_one = LOAD * m.loss_ratio(one)
lost_two = LOAD * m.loss_ratio(two)
core = m.RATINGS["medium"] * m.CORE_LOSS
axes[2].bar([0, 1], [lost_one / 1e3, lost_two / 1e3], color="#7f8c8d", label="line loss")
axes[2].bar([0, 1], [core / 1e3, 2 * core / 1e3], bottom=[lost_one / 1e3, lost_two / 1e3],
            color="#1d9e75", label="core loss")
for i_, v in enumerate([(lost_one + core) / 1e3, (lost_two + 2 * core) / 1e3]):
    axes[2].text(i_, v, f" {v:.0f} kW", ha="center", va="bottom", fontsize=9)
axes[2].set_xticks([0, 1], ["one", "two"])
axes[2].set_ylabel("kW lost delivering 20 MW")
axes[2].set_title("What the second transformer buys")
axes[2].legend(fontsize=8)
plt.tight_layout()
plt.show()
# %% [markdown]
# ## 6. How many transformers per block: downstream line loss against core loss
#
# A larger block, 140 × 70 tiles, drawing 40 MW, fed by 1, 2, 4 or 8 transformers spread along its
# edges. Each transformer feeds the poles nearest to it ("nearest first"), so more transformers
# shorten every route of the **downstream line loss** (the block's own wiring). But every switched-on
# transformer also loses its **core loss**, 0.1% of its rating, whatever the load.
#
# **How the mod rates a transformer for core loss:** each side's rating is the highest-rated pole
# wired to that side, and the transformer's rating is the *weaker* of the two sides:
#
#     rating = min(highest-rated pole on the upstream side, highest-rated pole on the downstream side)
#
# So it is **not** set by the upstream poles alone. A transformer fed from big or huge poles into a
# medium-pole block is rated by the medium side, 60 MW, so its core loss is 60 kW per transformer
# whatever feeds it. Inefficiency (1% of what passes through) does not depend on the number of
# transformers, so it is left out.

# %%
TOTAL_LOAD = 40e6
SPACING = {"small": 7, "medium": 7, "substation": 18}


def big_block(kind):
    """About 140 x 70 tiles wired with `kind` poles."""
    sp = SPACING[kind]
    nx, ny = int(round(140 / sp)) + 1, int(round(70 / sp)) + 1
    poles, wires = m.grid_poles("b", 0, 0, nx, ny, sp, kind)
    return poles, wires, nx, ny


def entry_poles(n, nx, ny):
    """Where n transformers connect: west edge middle, both short edges, or spread along the long edges."""
    if n == 1:
        return [f"b0_{ny // 2}"]
    if n == 2:
        return [f"b0_{ny // 2}", f"b{nx - 1}_{ny // 2}"]
    per_side = n // 2
    cols = [int(round((2 * k + 1) * (nx - 1) / (2 * per_side))) for k in range(per_side)]
    return [f"b{c}_0" for c in cols] + [f"b{c}_{ny - 1}" for c in cols]


def feed_block(kind, n, rating):
    """Downstream line loss (MW) and core loss (MW) for n transformers of the given rating."""
    poles, wires, nx, ny = big_block(kind)
    block = list(poles)
    entries = entry_poles(n, nx, ny)
    dists = {f"T{i + 1}": m.shortest_distances(poles, wires, e) for i, e in enumerate(entries)}
    own = m.ownership(dists)
    line = 0.0
    for t, d in dists.items():
        mine = [p for p in block if own[p] == t]
        if mine:
            line += TOTAL_LOAD * len(mine) / len(block) * m.loss_ratio(transformer_loss(d, mine))
    return line, n * rating * m.CORE_LOSS, (poles, wires, entries, dists, own)


def bar_panel(ax, rows, title):
    ns = [r[0] for r in rows]
    xs = np.arange(len(ns))
    ax.bar(xs - 0.2, [r[1] / 1e6 for r in rows], 0.4, label="downstream line loss", color="#7f8c8d")
    ax.bar(xs + 0.2, [r[2] / 1e6 for r in rows], 0.4, label="core loss", color="#1d9e75")
    tot = [(r[1] + r[2]) / 1e6 for r in rows]
    ax.plot(xs, tot, "o-", color="#d85a30", label="total")
    best = int(np.argmin(tot))
    ax.plot(xs[best], tot[best], "*", ms=16, color="#d85a30")
    ax.set_xticks(xs, [str(n) for n in ns])
    ax.set_xlabel("transformers feeding the block")
    ax.set_title(title, fontsize=10)


COUNTS = [1, 2, 4, 8, 16]

# %% [markdown]
# ### The medium block on the map

# %%
fig, axes = plt.subplots(2, 2, figsize=(15, 7.5))
for ax, n in zip(axes.flat, [1, 2, 4, 8]):
    line, core, (poles, wires, entries, dists, own) = feed_block("medium", n, m.RATINGS["medium"])
    d_own = {p: dists[own[p]][p] for p in poles}
    shown = dict(poles)
    for i, e in enumerate(entries):
        x, y, _ = poles[e]
        shown[f"T{i + 1}"] = (x + (-6 if n <= 2 and x == 0 else 6 if n <= 2 else 0),
                              y + (0 if n <= 2 else -6 if y == 0 else 6), "medium")
    m.draw_network(ax, shown, wires + [(f"T{i + 1}", e) for i, e in enumerate(entries)],
                   values={p: m.route_loss(d_own[p]) * 100 for p in poles}, vmin=0, vmax=8,
                   transformers=list(dists), colorbar_label="route loss (%)",
                   title=f"{n} transformer{'s' if n > 1 else ''}: downstream line loss "
                         f"{line / 1e6:.2f} MW, core loss {core / 1e6:.2f} MW")
plt.tight_layout()
plt.show()

# %%
rows = [(n, *feed_block("medium", n, m.RATINGS["medium"])[:2]) for n in COUNTS]
fig, ax = plt.subplots(figsize=(7, 3.8))
bar_panel(ax, rows, "A 140 x 70-tile block of medium poles drawing 40 MW:\ndownstream line loss against core loss")
ax.set_ylabel("MW lost delivering 40 MW")
ax.legend(fontsize=8)
plt.tight_layout()
plt.show()
# %% [markdown]
# The total is lowest at 4 transformers. Notebook 5 ("How many transformers?") goes through other
# cases: blocks of other poles, other loads and sizes, and what feeds the block.

# %% [markdown]
# ## 7. How big a block one transformer should feed
#
# Square blocks of medium poles from 35 to 280 tiles a side, all drawing 0.75 kW per square tile, so
# 0.9 MW for the smallest and 58.8 MW for the largest. (Power Overload caps a medium-pole network at
# 60 MW, and the block is one network however many transformers feed it, so that is as large as this
# block can get.) A bigger block means longer routes *and* more load, so the power lost grows much
# faster than the area. The second panel adds the escape: split the block between 2 or 4
# transformers and the curve bends back down, at 60 kW of core loss each.

# %%
sides = [35, 70, 140, 210, 280]
PER_TILE = 750          # W per square tile; 58.8 MW at 280 tiles a side, just under the 60 MW cap


def square_block(side):
    n = int(side / 7) + 1
    return m.grid_poles("b", 0, 0, n, n, 7, "medium"), n


def block_loss(side, n_tx):
    """Line loss (W) delivering the block's load with n_tx transformers, and their core loss."""
    (poles, wires), n = square_block(side)
    names = list(poles)
    if n_tx == 1:
        entries = [f"b0_{n // 2}"]
    elif n_tx == 2:
        entries = [f"b0_{n // 2}", f"b{n - 1}_{n // 2}"]
    else:
        entries = [f"b{n // 4}_0", f"b{3 * n // 4}_0", f"b{n // 4}_{n - 1}", f"b{3 * n // 4}_{n - 1}"]
    dists = {t: m.shortest_distances(poles, wires, e) for t, e in enumerate(entries)}
    own = m.ownership(dists)
    load = PER_TILE * side * side
    line = 0.0
    for t, d in dists.items():
        mine = [q for q in names if own[q] == t]
        if mine:
            line += load * len(mine) / len(names) * m.loss_ratio(transformer_loss(d, mine))
    return line, n_tx * m.RATINGS["medium"] * m.CORE_LOSS, load


fig, axes = plt.subplots(1, 2, figsize=(14, 4))
one_loss = []
for side in sides:
    (poles, wires), n = square_block(side)
    d = m.shortest_distances(poles, wires, f"b0_{n // 2}")
    one_loss.append(transformer_loss(d, list(poles)))
axes[0].plot(sides, [v * 100 for v in one_loss], "o-", color="#7f8c8d")
for side, v in zip(sides, one_loss):
    axes[0].annotate(f"{PER_TILE * side * side / 1e6:.0f} MW", (side, v * 100),
                     textcoords="offset points", xytext=(0, 7), ha="center", fontsize=8)
axes[0].set_xlabel("block side (tiles)")
axes[0].set_ylabel("downstream line loss (%)")
axes[0].set_title("One transformer at an edge: the loss grows with the side")

totals = {}
for n_tx, colour in [(1, "#7f8c8d"), (2, "#1d9e75"), (4, "#d85a30")]:
    share = []
    for side in sides:
        line, core, load = block_loss(side, n_tx)
        share.append((line + core) / load * 100)
    totals[n_tx] = share
    axes[1].plot(sides, share, "o-", color=colour, label=f"{n_tx} transformer{'s' if n_tx > 1 else ''}")
axes[1].set_xlabel("block side (tiles)")
axes[1].set_ylabel("line + core loss (% of the load)")
axes[1].set_title("Splitting the block pulls the curve back down")
axes[1].legend(fontsize=8)
plt.tight_layout()
plt.show()

for k, side in enumerate(sides):
    best = min(totals, key=lambda n_tx: totals[n_tx][k])
    load = PER_TILE * side * side
    print(f"{side:>4} tiles a side ({load / 1e6:6.1f} MW): cheapest with {best} transformer(s), "
          f"{totals[best][k]:.2f}% lost")

# %% [markdown]
# With one transformer the loss roughly doubles every time the side doubles, and the load quadruples,
# so the power lost grows about eightfold. The crossings in the second panel are the useful part: a
# small block is cheapest on one transformer, because a second one's core loss is a large share of a
# small load, and the bigger blocks are cheapest split two or four ways.

# %% [markdown]
# ## 8. Where the load sits: a hungry corner (machine weighting)
#
# By default the mod spreads a network's machine load evenly over its poles. With "weight machines
# by their live load" on, each pole counts with what the machines in its supply area draw. Here the
# block of section 1 draws 20 MW, but half of it comes from a cluster of 6 poles, either at the far
# corner or next to the transformer.

# %%
poles, wires = m.grid_poles("b", 7, 0, 10, 7, 7, "medium")
poles["T"] = (0, 21, "medium")
wires.append(("T", "b0_3"))
dist = m.shortest_distances(poles, wires, "T")
block = [p for p in poles if p != "T"]
far = ["b8_5", "b9_5", "b8_6", "b9_6", "b7_6", "b9_4"]
near = ["b0_2", "b0_3", "b0_4", "b1_2", "b1_3", "b1_4"]

cases = {"even (option off)": {p: 1.0 for p in block}}
for name, hot_poles in [("hungry far corner", far), ("hungry near T", near)]:
    w = {p: 10e6 / (len(block) - len(hot_poles)) for p in block}
    for p in hot_poles:
        w[p] = 10e6 / len(hot_poles)
    cases[name] = w

fig, axes = plt.subplots(1, 3, figsize=(16, 4.2))
case_loss = {}
for ax, (name, w) in zip(axes, cases.items()):
    total = sum(w.values())
    lost = {p: 20e6 * w[p] / total * m.loss_ratio(m.route_loss(dist[p])) for p in block}
    case_loss[name] = transformer_loss(dist, block, w)
    m.draw_network(ax, poles, wires, values={p: lost[p] / 1e3 for p in block}, cmap="Oranges",
                   sizes={p: 12 + 20e6 * w[p] / total / 15e3 for p in block}, transformers=["T"],
                   colorbar_label="power lost (kW)",
                   title=f"{name}: downstream line loss {case_loss[name] * 100:.2f}%")
plt.suptitle('The map setting "Line losses: weight machines by their live load": the same 20 MW of\n'
             "machines placed three ways. With the setting off the mod charges the left panel for all three.",
             fontsize=11)
plt.tight_layout()
plt.show()
# %% [markdown]
# Dot size is each pole's load, colour the power lost delivering it. The same 20 MW costs about twice
# as much when the heavy machines sit in the far corner. With the option off the mod cannot tell
# these apart and charges the even-spread value: put heavy machines near the transformer, or give
# them their own transformer, which the mod then measures exactly.
