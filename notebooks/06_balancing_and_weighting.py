# ---
# jupyter:
#   jupytext:
#     text_representation:
#       extension: .py
#       format_name: percent
# ---

# %% [markdown]
# # 6. Several sources on one network: who feeds whom
#
# With one transformer on a network there is nothing to decide: it serves every consumer, and its
# downstream line loss is the average over its routes. With several, the mod has to decide how much
# each source sends to each consumer, because that split is what its line loss is averaged over.
#
# Two map settings decide it:
#
# | Setting | Default | Off | On |
# |---|---|---|---|
# | Line losses: feed nearest consumers first | **on** | every source serves every consumer in proportion to what it draws | the flows are pulled towards short routes, by `1/d` |
# | Line losses: weight machines by their live load | **off** | machine load counts as spread evenly over the network's poles | each pole counts for what its own machines draw |
#
# 1. Two transformers feeding three consumers: what "nearest first" changes
# 2. A line of machines fed from both ends: how close that is to real current division
# 3. A steam field: here the mod has no choice to make
# 4. Two transformers on one steam field: here it does, and pairs them
# 5. Machine weighting: what the second setting changes

# %%
import numpy as np
import matplotlib.pyplot as plt

import lineloss_model as m

# %% [markdown]
# ## 1. Two transformers feeding three consumers
#
# A and B sit at opposite corners of a big-pole network and supply 25 MW each. X, Y and Z draw 20,
# 20 and 10 MW. Nothing about the poles changes between the two panels; only the decision of who
# feeds whom. Arrow width is the flow; the matrices below carry the same flows as numbers, each
# with the route loss it travels over.

# %%
net_poles, net_wires = m.grid_poles("n", 0, 0, 9, 4, 30, "big")
src = {"A": "n0_0", "B": "n8_3"}
dst = {"X": "n1_1", "Y": "n7_2", "Z": "n4_2"}
demand = np.array([20e6, 20e6, 10e6])
supply = np.array([25e6, 25e6])
dists = {s: m.shortest_distances(net_poles, net_wires, p) for s, p in src.items()}
D = np.array([[dists[s][dst[k]] for k in dst] for s in src])

off = np.outer(supply / supply.sum(), demand)          # setting off: proportional to demand
on = m.sinkhorn(1 / np.maximum(D, 1), supply, demand)  # setting on: pulled towards short routes

fig, axes = plt.subplots(2, 2, figsize=(15, 8), gridspec_kw={"height_ratios": [1.55, 1]})
totals = {}
for col, (flows, title) in enumerate([(off, "Setting OFF: every source feeds every consumer"),
                                      (on, "Setting ON (the default): nearest consumers first")]):
    ax = axes[0][col]
    m.draw_network(ax, net_poles, net_wires)
    for i, s in enumerate(src):
        xs, ys, _ = net_poles[src[s]]
        for j, k in enumerate(dst):
            xd, yd, _ = net_poles[dst[k]]
            f = flows[i, j]
            if f < 1e5:
                continue
            ax.annotate("", xy=(xd, yd), xytext=(xs, ys),
                        arrowprops=dict(arrowstyle="-|>", lw=0.4 + f / 2.5e6,
                                        color="#378add" if s == "A" else "#d85a30", alpha=0.75,
                                        shrinkA=8, shrinkB=8, connectionstyle="arc3,rad=0.12"))
    for name, p_ in {**src, **dst}.items():
        ax.annotate(name, net_poles[p_][:2], textcoords="offset points", xytext=(6, 6),
                    fontsize=10, weight="bold")
    L = m.weighted_route_loss(flows, D)
    lost = (flows * m.loss_ratio(np.vectorize(m.route_loss)(D))).sum()
    totals[title] = lost
    ax.set_title(f"{title}\ndownstream line loss A {L[0] * 100:.2f}%, B {L[1] * 100:.2f}%  "
                 f"— {lost / 1e6:.2f} MW lost in all")

    # the same split as a matrix: rows are the sources, columns the consumers
    mx = axes[1][col]
    mx.imshow(flows / 1e6, cmap="Oranges", vmin=0, vmax=20)
    mx.set_xticks(range(len(dst)), list(dst))
    mx.set_yticks(range(len(src)), list(src))
    for i in range(len(src)):
        for k in range(len(dst)):
            mx.text(k, i, f"{flows[i, k] / 1e6:.1f} MW\nover {m.route_loss(D[i, k]) * 100:.1f}%",
                    ha="center", va="center", fontsize=9)
    mx.set_title("who sends how much, and over what route loss", fontsize=10)
    mx.set_xlabel("consumer")
    mx.set_ylabel("source")
plt.suptitle('The map setting "Line losses: feed nearest consumers first"\n'
             "two transformers supplying 25 MW each, three consumers drawing 20, 20 and 10 MW",
             fontsize=12)
plt.tight_layout()
plt.show()

print("route distances (tiles):")
print("      " + "".join(f"{k:>8}" for k in dst))
for i, s in enumerate(src):
    print(f"{s:>6}" + "".join(f"{D[i, j]:8.0f}" for j in range(len(dst))))
print("\n" + "\n".join(f"{t}: {v / 1e6:.2f} MW lost" for t, v in totals.items()))

# %% [markdown]
# **The point:** with the setting on, X takes most of its power from A and Y from B, so the long
# cross-network arrows thin out and the total lost falls. The pull is `1/d`, not a hard assignment:
# Z, in the middle, still draws from both, and a consumer whose nearest source is too small to feed
# it keeps taking the rest from far away. Machines on the network's own poles are treated as one
# more consumer at each pole and are balanced the same way.

# %% [markdown]
# ## 2. A line of machines fed from both ends
#
# In a real line fed from both ends, each load takes a share from each end set by where it sits:
# `d_other / (d_A + d_B)`. The mod does not simulate current; it gives each source the poles nearer
# to it and balances the two regions by `1/d`. This section checks how far apart those two answers
# are.
#
# 20 MW of machines spread along 21 big poles, 30 tiles apart, with a feeder at one or both ends.

# %%
x = 30 * np.arange(1, 22, dtype=float)       # pole positions
L_end = 660.0                                # second feeder at x = 660
one_feeder = np.mean([m.route_loss(xi) for xi in x])

share_A = (L_end - x) / L_end                # exact current division
exact = np.mean(share_A * x + (1 - share_A) * (L_end - x))

own_A = x <= L_end / 2                       # the mod: regions, balanced by 1/d
regions = [own_A, ~own_A]
K = np.array([[np.mean(1 / np.maximum(np.abs(src_x - x[r]), 1)) for r in regions] for src_x in (0.0, L_end)])
Dreg = np.array([[np.mean(np.abs(src_x - x[r])) for r in regions] for src_x in (0.0, L_end)])
f = m.sinkhorn(K, [10, 10], [r.sum() for r in regions])
mod_d = (f * Dreg).sum() / f.sum()

poles = {f"p{k}": (float(xi), 0.0, "big") for k, xi in enumerate(x)}
poles["A"] = (0.0, 0.0, "big")
poles["B"] = (L_end, 0.0, "big")
wires = ([("A", "p0")] + [(f"p{k}", f"p{k + 1}") for k in range(20)] + [("p20", "B")])

fig, (ax, bx) = plt.subplots(2, 1, figsize=(12, 5), gridspec_kw={"height_ratios": [1, 1.2]})
m.draw_network(ax, poles, wires, transformers=["A", "B"],
               pole_colours={f"p{k}": "#85b7eb" if own_A[k] else "#f0997b" for k in range(21)},
               sizes={f"p{k}": 70 for k in range(21)},
               title="Each pole goes to the nearer feeder (blue A, orange B)")
ax.set_ylim(-20, 20)
ax.set_aspect("auto")
bx.plot(x, share_A * 100, color="#378add", lw=2, label="exact: share taken from A")
bx.plot(x, np.where(own_A, 100, 0), color="#378add", ls="--", lw=1.5, label="the mod: A's region")
bx.set_xlabel("position along the line (tiles)")
bx.set_ylabel("share from A (%)")
bx.legend(fontsize=8)
bx.set_title("The mod replaces a gradual split with two regions")
plt.tight_layout()
plt.show()

print(f"one feeder:                    mean distance {np.mean(x):6.1f}  loss {one_feeder * 100:.2f}%")
print(f"two feeders, exact division:   mean distance {exact:6.1f}  loss {m.route_loss(exact) * 100:.2f}%")
print(f"two feeders, the mod:          mean distance {mod_d:6.1f}  loss {m.route_loss(mod_d) * 100:.2f}%")

# %% [markdown]
# **The point:** the hard region boundary is a coarse stand-in for a gradual split, but it lands
# within a few hundredths of a percent of the exact answer. Feeding from both ends cuts the
# machines' line loss by about a third, not by half, because in a real line power from each end
# still reaches loads on the far side.

# %% [markdown]
# ## 3. A steam field: here the mod has no choice to make
#
# On the generation side the mod charges a transformer for the wires between it and the engines that
# feed it. Every pole is weighted by the **rated output** of the generators in its supply area — not
# by its distance. A single transformer has no decision to make: all the engines on its network pool
# their output, so it pays the output-weighted average, however the field is laid out.
#
# 10 big poles run out from the transformer's input, 30 tiles apart, carrying power only. Each has a
# medium tap pole beside it that collects the engines around it, and the engines sit only by the
# five farthest taps.

# %%
TAP = m.wire_cost(5, "big", "medium")
pole_d = 30 * np.arange(1, 11, dtype=float) + TAP
engines = np.array([0, 0, 0, 0, 0, 2, 2, 2, 2, 2], float)      # engines on each tap
gen_loss = m.loss_from_ratio((engines * m.loss_ratio(np.vectorize(m.route_loss)(pole_d))).sum() / engines.sum())
nearest_only = m.route_loss(pole_d[5])                          # if it could draw from the nearest engines only
draw = 10.21e6

poles = {f"b{k}": (30.0 * k, 0.0, "big") for k in range(1, 11)}
poles.update({f"p{k}": (30.0 * k, 12.0, "medium") for k in range(1, 11)})
poles["T"] = (0.0, 0.0, "big")
wires = ([("T", "b1")] + [(f"b{k}", f"b{k + 1}") for k in range(1, 10)]
         + [(f"b{k}", f"p{k}") for k in range(1, 11)])
dist = m.shortest_distances(poles, wires, "T")

fig, (ax, bx) = plt.subplots(2, 1, figsize=(12, 6), gridspec_kw={"height_ratios": [1, 1]})
m.draw_network(ax, poles, wires, values={p: m.route_loss(dist[p]) * 100 for p in dist if p != "T"},
               vmin=0, vmax=8, transformers=["T"], colorbar_label="route loss (%)",
               labels={f"p{k}": f"d {dist[f'p{k}']:.0f}" for k in range(1, 11)})
for k in range(1, 11):
    for e in range(int(engines[k - 1])):
        ax.scatter([30.0 * k - 5 + 10 * e], [22], marker="s", s=90, c="#ef9f27", edgecolor="k",
                   linewidth=0.4, zorder=3)
ax.annotate("steam engines", (300, 26), fontsize=9, color="#854f0b")
ax.set_ylim(-14, 34)
ax.set_aspect("auto")
ax.set_title(f"The engines all sit at the far end: upstream line loss {gen_loss * 100:.2f}% "
             f"(generation-weighted distance {(engines * pole_d).sum() / engines.sum():.0f} tiles)")

bx.bar(pole_d, engines, width=16, color="#ef9f27", edgecolor="k", linewidth=0.4, label="engines on this tap")
bx2 = bx.twinx()
bx2.plot(pole_d, np.vectorize(m.route_loss)(pole_d) * 100, "o-", color="#d85a30", label="route loss")
bx2.axhline(gen_loss * 100, color="#993c1d", ls="--", lw=1.5)
bx2.annotate(f"what the transformer pays: {gen_loss * 100:.2f}%", (pole_d[0], gen_loss * 100),
             textcoords="offset points", xytext=(4, 5), fontsize=8, color="#993c1d")
bx.set_xlabel("resistance-weighted distance from the transformer (tiles)")
bx.set_ylabel("engines")
bx2.set_ylabel("route loss (%)")
bx.set_title("Rated output decides the weight, and the five empty taps count for nothing")
plt.tight_layout()
plt.show()

print(f"pays the output-weighted average over its engines: {gen_loss * 100:.2f}%")
print(f"if it could draw from the nearest engines only:     {nearest_only * 100:.2f}%")

# %% [markdown]
# **The point:** the five near taps carry no generation, so they do not pull the average down at all
# — what matters is where the *engines* are, not where the poles are. The mod does not let the
# transformer favour the nearest engines: on one network every generator pools its output and the
# game decides which one supplies what, so the transformer pays the average. Favouring is only
# possible when there is a choice to make, which is the next section.

# %% [markdown]
# ## 4. Two transformers on one steam field: now there is a choice
#
# 11 taps along 300 tiles of big poles, one engine each, with transformer A drawing at the west end
# and B at the east end, 10 MW apiece. Each engine now has two possible destinations, so the mod
# pairs them: every engine goes to its nearest transformer, and the two groups are balanced by
# `1/d`, exactly as consumers are in section 1. Without pairing both transformers would pay the
# field's overall average.

# %%
x = 30 * np.arange(0, 11, dtype=float)
xa, xb = -30.0, 330.0
d_a, d_b = x - xa + TAP, xb - x + TAP
avg_a = m.loss_from_ratio(np.mean(m.loss_ratio(np.vectorize(m.route_loss)(d_a))))
own_a = d_a <= d_b
groups = [own_a, ~own_a]
K = np.array([[np.mean(1 / np.maximum(dd[g], 1)) for g in groups] for dd in (d_a, d_b)]).T
G = np.array([[np.mean(m.loss_ratio(np.vectorize(m.route_loss)(dd[g]))) for g in groups] for dd in (d_a, d_b)]).T
f = m.sinkhorn(K, [g.sum() for g in groups], [10, 10])
paired = m.loss_from_ratio((f * G).sum(axis=0) / f.sum(axis=0))

poles = {f"k{k}": (x[k], 0.0, "big") for k in range(11)}
poles.update({f"e{k}": (x[k], 12.0, "medium") for k in range(11)})
poles["A"] = (xa, 0.0, "big")
poles["B"] = (xb, 0.0, "big")
wires = ([("A", "k0")] + [(f"k{k}", f"k{k + 1}") for k in range(10)] + [("k10", "B")]
         + [(f"k{k}", f"e{k}") for k in range(11)])
fig, ax = plt.subplots(figsize=(12, 3.2))
m.draw_network(ax, poles, wires, transformers=["A", "B"],
               pole_colours={f"e{k}": "#85b7eb" if own_a[k] else "#f0997b" for k in range(11)},
               labels={f"e{k}": f"{min(d_a[k], d_b[k]):.0f}" for k in range(11)},
               sizes={f"e{k}": 90 for k in range(11)})
for k in range(11):
    ax.scatter([x[k]], [22], marker="s", s=70, c="#ef9f27", edgecolor="k", linewidth=0.4, zorder=3)
ax.set_ylim(-14, 30)
ax.set_aspect("auto")
ax.set_title(f"Each engine goes to its nearer transformer (blue A, orange B), labelled with that distance\n"
             f"paired: A {paired[0] * 100:.2f}%, B {paired[1] * 100:.2f}%   —   unpaired, both {avg_a * 100:.2f}%")
plt.tight_layout()
plt.show()

# %% [markdown]
# **The point:** pairing takes both transformers from 4.76% to about 3.7%, for free, because each
# one is charged for the half of the field it actually sits next to. Build a plant to be drawn from
# at both ends and the mod rewards it.

# %% [markdown]
# ## 5. Machine weighting: what the second setting changes
#
# By default the mod cannot see where machines are: it spreads a network's machine load evenly over
# the poles that can power machines. Turn "weight machines by their live load" on and each pole
# counts for what its own machines draw right now.
#
# 21 big poles from a transformer, each with a medium tap, lamps at the first 20 taps (10 MW in
# total) and one 100 MW machine at the far end.

# %%
x = 30 * np.arange(1, 22, dtype=float) + TAP
loss = np.vectorize(m.route_loss)(x)
even = m.loss_from_ratio(m.loss_ratio(loss).mean())
load_running = np.r_[np.full(20, 10e6 / 20), 100e6]
load_idle = np.r_[np.full(20, 10e6 / 20), 0.0]
weighted = m.loss_from_ratio((load_running * m.loss_ratio(loss)).sum() / load_running.sum())
weighted_idle = m.loss_from_ratio((load_idle * m.loss_ratio(loss)).sum() / load_idle.sum())

lost_on = load_running * m.loss_ratio(loss)
lost_off = np.full(21, load_running.sum() / 21) * m.loss_ratio(loss)

fig, axes = plt.subplots(1, 2, figsize=(13, 3.6), sharey=True)
for ax, lost, title in [(axes[0], lost_off, f"setting OFF: load spread evenly, {even * 100:.2f}%"),
                        (axes[1], lost_on, f"setting ON: load located, {weighted * 100:.2f}%")]:
    ax.scatter(x, np.zeros_like(x), s=np.clip(lost / 2e4, 8, 1500),
               c=np.log10(np.maximum(lost, 1e3)), cmap="autumn_r", vmin=3, vmax=7.5,
               edgecolor="k", linewidth=0.3)
    ax.set_title(f"{title}\n{lost.sum() / 1e6:.1f} MW lost in all")
    ax.set_xlabel("resistance-weighted distance from the transformer (tiles)")
    ax.set_yticks([])
plt.suptitle("What the \"Power lost per pole\" map view draws: load x L/(1-L) at each pole")
plt.tight_layout()
plt.show()

print(f"machines spread evenly (setting off): {even * 100:.2f}%")
print(f"located, big machine running:         {weighted * 100:.2f}%")
print(f"located, big machine idle:            {weighted_idle * 100:.2f}%")

# %% [markdown]
# **The point:** the same 110 MW is charged 8.7% with the setting off and 15.3% with it on, because
# the load that matters sits at the far end of the line. With the setting on the figure also
# breathes with the factory: when the big machine stops it falls back to the lamps' 8.3%. That is
# what the extra entity searches buy, and why the setting is opt-in.
