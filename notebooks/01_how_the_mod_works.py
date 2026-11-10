# ---
# jupyter:
#   jupytext:
#     text_representation:
#       extension: .py
#       format_name: percent
# ---

# %% [markdown]
# # 1. How the mod works
#
# The model in one page, with the two worked examples from the mod's FAQ.
#
# 1. Resistance per pole type
# 2. The same 100 tiles on different poles
# 3. Loss versus length, with the 95% cap
# 4. Shortest path over a small grid
# 5. Why the loss is charged as `delivered × L / (1 − L)`
# 6. Why each route is capped on its own
# 7. Why the mod averages L / (1 − L), not L
# 8. FAQ example 1: a generator, a trunk and a machine line
# 9. FAQ example 2 drawn to scale, with a loss waterfall
# 10. A bigger base: a plant, a trunk, two branches and an outpost
#
# ### Words used the same way in every notebook
#
# | Term | Meaning |
# |---|---|
# | **map distance** | plain tiles between two poles. Every map's axes are map tiles. |
# | **resistance-weighted distance**, `d` | a path's length with each wire multiplied by its poles' resistance (big = 1, huge 0.32, substation 1.49, medium 2.24, small 5.48). "Tiles of big-pole wire". Every `d` in a label is this. |
# | **route** `i` | one transformer to one consumer on the network it feeds: another transformer's input, or a pole with machines on it. A transformer has as many routes as it has consumers, each with its own `dᵢ`. |
# | **route loss**, `Lᵢ` | the loss of route `i`: `0.025% × dᵢ`, capped at 95%. A pole's colour on a map is always its route loss. |
# | **loss ratio**, `Lᵢ / (1 − Lᵢ)` | watts lost per watt *delivered* on route `i`, while `Lᵢ` is watts lost per watt *sent*. Averages are taken of the ratio, never of `Lᵢ`. |
# | **downstream line loss** | a transformer's own figure: the loss ratios of its routes averaged with the power each consumer draws as the weight, written back as a share of its output. |
# | **upstream line loss** | the loss of the power arriving at a transformer, built the same way from the routes that reach *it*: one `Lᵢ` per feeder, weighted by the power that feeder sends it. |
# | **collection network / trunk / block** | the three stages: generators to the step-up transformer; the long haul on big or huge poles; the poles that actually power machines. |

# %%
import math

import numpy as np
import matplotlib.pyplot as plt

import lineloss_model as m


def waterfall(ax, generated, steps, delivered, title, delivered_label="Reaching machines"):
    """From the power generated, down one loss at a time, to what reaches the machines."""
    off = (generated - delivered) / 1e6 * 0.06 + 0.05
    level = generated
    ax.bar(0, generated / 1e6, color="#7f8c8d")
    ax.text(0, generated / 1e6 + off, f"{generated / 1e6:.2f}", ha="center", fontsize=8)
    for i, (name, v) in enumerate(steps, start=1):
        ax.bar(i, v / 1e6, bottom=(level - v) / 1e6, color="#d85a30")
        level -= v
        ax.text(i, level / 1e6 + off, f"{v / 1e6:.2f}", ha="center", fontsize=8)
    ax.bar(len(steps) + 1, level / 1e6, color="#1d9e75")
    ax.text(len(steps) + 1, level / 1e6 + off, f"{level / 1e6:.2f}", ha="center", fontsize=8)
    ax.set_xticks(range(len(steps) + 2), ["Generated"] + [n for n, _ in steps] + [delivered_label],
                  rotation=40, ha="right")
    ax.set_ylim(delivered / 1e6 * 0.97, generated / 1e6 * 1.03)
    ax.set_ylabel("MW")
    ax.set_title(title)


def transformer_loss(dist, poles, weights=None):
    """Machines spread over the poles (or weighted): L/(1-L) averaged, back to a share of output."""
    ps = [p for p in poles if p in dist]
    w = np.array([1.0 if weights is None else weights.get(p, 0.0) for p in ps])
    g = np.array([m.loss_ratio(m.route_loss(dist[p])) for p in ps])
    return m.loss_from_ratio((w * g).sum() / w.sum())


# %% [markdown]
# ## 1. Resistance per pole type
#
# `r = sqrt(P_big / P_pole)`: a pole rated for 30 times less power than a big pole has about 5.5 times
# its resistance per tile.

# %%
kinds = ["huge", "big", "substation", "medium", "small"]
rating = [m.RATINGS[k] / 1e6 for k in kinds]
res = [m.resistance(k) for k in kinds]
loss100 = [m.route_loss(100 * r) * 100 for r in res]

fig, axes = plt.subplots(1, 3, figsize=(14, 3.6))
for ax, vals, title, unit, fmt in [
        (axes[0], rating, "What Power Overload rates the pole at", "MW", "{:,.0f}"),
        (axes[1], res, "Resistance per tile, r = sqrt(P_big / P_pole)", "x a big pole", "{:.2f}"),
        (axes[2], loss100, "Route loss over 100 tiles of that pole", "%", "{:.1f}")]:
    ax.barh(range(len(kinds)), vals, color=[m.POLE_STYLE[k][1] for k in kinds])
    ax.set_yticks(range(len(kinds)), kinds)
    ax.invert_yaxis()
    for i, v in enumerate(vals):
        ax.text(v, i, " " + fmt.format(v), va="center", fontsize=8)
    ax.set_xlabel(unit)
    ax.set_title(title, fontsize=10)
    ax.margins(x=0.25)
axes[0].set_xscale("log")
plt.tight_layout()
plt.show()

# %% [markdown]
# ## 2. The same 100 tiles on different poles
#
# The third panel above is 100 tiles of wire carried by each pole type: 0.8% lost on huge poles,
# 13.7% on small ones. The physical length is the same in every case; only the resistance differs.
# %% [markdown]
# ## 3. Loss versus physical length, with the 95% cap
#
# Every route is capped on its own: at least 5% of the power on any route arrives.

# %%
length = np.linspace(0, 8000, 400)
fig, ax = plt.subplots(figsize=(8, 4))
for pole in ["huge", "big", "medium", "small"]:
    ax.plot(length, [m.route_loss(L * m.resistance(pole)) * 100 for L in length], label=pole)
ax.axhline(95, color="grey", ls="--", lw=0.8)
ax.set_xlabel("map length of the route (tiles)")
ax.set_ylabel("route loss (%)")
ax.set_title("Route loss by pole type (default 0.025% per tile, cap 95%)")
ax.legend()
plt.show()

# %% [markdown]
# ## 4. Shortest path over a small grid
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

# The path the search takes to each pole, for the table below
paths = {"B1": "T-B1", "B2": "T-B1-B2", "B3": "T-B1-B2-B3", "M1": "trunk, then M1",
         "M2": "trunk, M1, M2", "S1": "B1-S1", "S2": "B1-S1-S2", "S3": "B1-S1-S2-S3"}

fig, (ax, tx) = plt.subplots(1, 2, figsize=(13, 4), gridspec_kw={"width_ratios": [1.4, 1]})
m.draw_network(ax, poles, wires, values={p: m.route_loss(dist[p]) * 100 for p in poles if p != "T"},
               vmin=0, vmax=6, transformers=["T"], colorbar_label="route loss (%)",
               labels={p: p for p in poles if p != "T"}, label_size=9, shape_legend=True,
               title="The cheapest path from T to every pole")
ax.set_ylim(-14, 30)

tx.axis("off")
rows = [[p, f"{dist[p]:.0f}", f"{m.route_loss(dist[p]) * 100:.2f}%", paths[p]]
        for p in ["B1", "B2", "B3", "M1", "M2", "S1", "S2", "S3"]]
table = tx.table(cellText=rows, colLabels=["pole", "d", "route loss", "path taken"],
                 cellLoc="left", colLoc="left", loc="upper center")
table.auto_set_font_size(False)
table.set_fontsize(9)
table.scale(1, 1.35)
for k, cell in table.get_celld().items():
    cell.set_edgecolor("#d3d1c7")
    if k[0] == 0:
        cell.set_text_props(weight="bold")
tx.set_title("Resistance-weighted distance from T", fontsize=10)
plt.tight_layout()
plt.show()
# %% [markdown]
# M2 is 18 tiles from S3 over small poles but reached more cheaply through the big trunk and two
# medium wires: the search picks that route, so its loss stays low.
# %% [markdown]
# ## 5. Why the loss is charged as `delivered × L / (1 − L)`
#
# The picture below is one transformer in order, upstream on the left, downstream on the right. The
# mod adds two hidden consumers: "Transf. ineff." on the upstream network and "Line loss" on the
# downstream one. They are ordinary consumers, so the transformer has to supply them too.
#
# That is the catch. The "Line loss" consumer hangs on the network the transformer feeds, so the
# transformer's measured output already contains it. Setting the charge to `L × measured output`
# would chase its own tail, climbing a little with every measurement. Computing it from the power
# actually delivered to the machines lands on the right value at once.

# %%
fig, ax = plt.subplots(figsize=(12, 3.4))
ax.set_xlim(0, 100)
ax.set_ylim(0, 40)
ax.axis("off")
boxes = [(2, 22, 16, 12, "Upstream\nnetwork", "#d3d1c7"),
         (26, 20, 14, 16, "Transformer", "#1d9e75"),
         (48, 22, 18, 12, "Downstream\nnetwork", "#d3d1c7"),
         (74, 22, 20, 12, "Machines\ndelivered 10 MW", "#85b7eb")]
for x, y, w, h, label, colour in boxes:
    ax.add_patch(plt.Rectangle((x, y), w, h, facecolor=colour, edgecolor="k", lw=0.6))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center", fontsize=9)
for x0, x1, y, label in [(18, 26, 28, "draws"), (40, 48, 28, "output"), (66, 74, 28, "delivered")]:
    ax.annotate("", xy=(x1, y), xytext=(x0, y), arrowprops=dict(arrowstyle="-|>", color="k", lw=1.2))
    ax.text((x0 + x1) / 2, y + 1.5, label, ha="center", fontsize=8)
for cx, cy, label in [(10, 8, 'hidden consumer\n"Transf. ineff."'), (57, 8, 'hidden consumer\n"Line loss"')]:
    ax.add_patch(plt.Rectangle((cx - 9, cy - 5), 18, 10, facecolor="#f5c4b3", edgecolor="k", lw=0.6))
    ax.text(cx, cy, label, ha="center", va="center", fontsize=8)
    ax.annotate("", xy=(cx, cy + 5), xytext=(cx, 22), arrowprops=dict(arrowstyle="-|>", color="#993c1d", lw=1.2))
ax.text(68, 14, "sits on the downstream network,\nso the output already includes it",
        ha="left", va="center", fontsize=8, color="#993c1d")
ax.set_title("One transformer, upstream on the left, downstream on the right")
plt.show()

# %% [markdown]
# With a 95% route loss, 10 MW of machines need 200 MW sent out. The naive rule creeps up to that
# value one measurement at a time; the mod writes it down immediately.

# %%
L, delivered = 0.95, 10.0
out, history = delivered, []
for _ in range(60):
    out = delivered + L * out            # naive: charge taken from the measured output
    history.append(out)
one_step = delivered * (1 + L / (1 - L))  # = delivered / (1 - L)

fig, ax = plt.subplots(figsize=(8, 3.4))
ax.plot(range(1, 61), history, color="#7f8c8d", lw=2, label="naive: charge from the measured output")
ax.axhline(one_step, color="#d85a30", ls="--", lw=2,
           label=f"the mod: delivered x L/(1-L), {one_step:.0f} MW at once")
ax.annotate("still climbing after a minute of measurements", xy=(45, history[44]),
            xytext=(22, one_step * 0.55), fontsize=8,
            arrowprops=dict(arrowstyle="-|>", color="#7f8c8d", lw=1))
ax.set_xlabel("measurements (one per second)")
ax.set_ylabel("transformer output (MW)")
ax.set_title("Charging from the measured output chases its own tail")
ax.legend(fontsize=8, loc="lower right")
plt.tight_layout()
plt.show()
# %% [markdown]
# ## 6. Why the cap is applied per route
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
# Each route is capped and charged on its own: the short route loses 2.5% of what it carries, the long
# one 95%, so it must be sent 20 times what it delivers. Over both routes the source loses about 90%
# of its output, close to the cap but set by the routes themselves, not by their average distance.

# %% [markdown]
# ## 7. Why the mod averages L / (1 − L), not L
#
# They are two ways of measuring the same route, and the difference only shows up when the loss is
# large:
#
# * `L` is the share of what is **sent** that disappears on the way.
# * `L / (1 − L)` is what must be **added** for every watt that actually arrives.
#
# At 2% they are 0.020 and 0.0204, near enough the same number, which is why the two curves look
# alike at the left of the first panel. At 50% you must send double; at 95%, twenty times. Averaging
# `L` first and converting afterwards — what the mod did before 0.1.3 — therefore under-charged a
# transformer whose routes differ a lot.

# %%
Ls = np.linspace(0, 0.95, 200)
delivered = 10.0                                  # MW that must arrive
sent = delivered / (1 - Ls)

fig, axes = plt.subplots(1, 2, figsize=(13, 4))
axes[0].plot(Ls * 100, sent, color="#d85a30", lw=2, label="sent")
axes[0].plot(Ls * 100, sent - delivered, color="#993c1d", lw=2, ls="--", label="lost on the way")
axes[0].axhline(delivered, color="#1d9e75", lw=2, label="delivered to the machines")
for mark, (dx, dy, ha) in zip((10, 50, 95), [(10, -4, "left"), (-10, 8, "right"), (-10, 2, "right")]):
    y = delivered / (1 - mark / 100)
    axes[0].plot(mark, y, "o", color="#d85a30")
    axes[0].annotate(f"L = {mark}%: send {y:.0f} MW", (mark, y), textcoords="offset points",
                     xytext=(dx, dy), ha=ha, fontsize=8)
axes[0].set_xlabel("route loss L (%)")
axes[0].set_ylabel("MW")
axes[0].set_ylim(0, 215)
axes[0].set_title("What it takes to deliver 10 MW down one route")
axes[0].legend(fontsize=8)

pairs = [(0.02, 0.10), (0.05, 0.30), (0.10, 0.60), (0.025, 0.95)]
half = 5.0                                        # MW delivered on each of the two routes
old = [2 * half * m.loss_ratio((a + b) / 2) for a, b in pairs]          # average L, then convert
new_ = [half * (m.loss_ratio(a) + m.loss_ratio(b)) for a, b in pairs]   # each route on its own
x = np.arange(len(pairs))
axes[1].bar(x - 0.2, old, 0.4, label="average L first (before 0.1.3)", color="#b4b2a9")
axes[1].bar(x + 0.2, new_, 0.4, label="each route charged on its own (0.1.3)", color="#d85a30")
for i_, (o, n_) in enumerate(zip(old, new_)):
    axes[1].text(i_ - 0.2, o, f"{o:.1f}", ha="center", va="bottom", fontsize=8)
    axes[1].text(i_ + 0.2, n_, f"{n_:.1f}", ha="center", va="bottom", fontsize=8)
axes[1].set_xticks(x, [f"{a * 100:g}% and {b * 100:g}%" for a, b in pairs])
axes[1].set_xlabel("the two routes' losses")
axes[1].set_yscale("log")
axes[1].set_ylabel("MW lost")
axes[1].set_title("A transformer delivering 5 MW down each of two routes")
axes[1].legend(fontsize=8)
plt.tight_layout()
plt.show()

print("MW lost delivering 5 MW down each of two routes:")
for (a, b), o, n_ in zip(pairs, old, new_):
    print(f"  {a * 100:4.1f}% and {b * 100:4.1f}%:  average L first {o:6.2f}   each on its own {n_:6.2f}")

# %% [markdown]
# ## 8. FAQ example 1: generator → T1 → 300 tiles of big poles → T2 → 10 MW of machines
#
# T1 has big poles on both sides (rated 300 MW); T2 goes from big to medium poles (rated 60 MW). The
# machines are spread along 20 tiles of medium poles: every pole's route counts equally, and T2 loses
# the sum of their losses (0.56% of its output; the middle pole sits at 10 × 2.24 = 22.4).

# %%
t2 = m.transformer_stage(10e6, m.spread_line_loss(20, m.resistance("medium")), rating=60e6)
t1 = m.transformer_stage(t2["draw"], m.route_loss(300), rating=300e6)
rows = [
    ("Generator output", t1["draw"], ""),
    ("T1 core loss (0.1% of 300 MW)", t1["core"], "Transf. ineff. (T1)"),
    ("T1 inefficiency (1%)", t1["ineff"], "Transf. ineff. (T1)"),
    ("300-tile line (7.5%)", t1["line"], "Line loss (T1)"),
    ("T2 core loss (0.1% of 60 MW)", t2["core"], "Transf. ineff. (T2)"),
    ("T2 inefficiency (1%)", t2["ineff"], "Transf. ineff. (T2)"),
    ("Wires to the machines (0.55%)", t2["line"], "Line loss (T2)"),
    ("Reaching the machines", 10e6, ""),
]
for name, value, consumer in rows:
    print(f"{name:<34}{value / 1e6:8.2f} MW   {consumer}")
lost = t1["draw"] - 10e6
print(f"\nLost {lost / 1e6:.2f} MW = {lost / t1['draw'] * 100:.1f}% of generation")

# %% [markdown]
# ## 9. FAQ example 2 drawn to scale
#
# Three steam engines on medium poles 5, 10 and 15 tiles from T1; a big-pole trunk of 100 tiles to
# T2 and T3; T2 feeds 30 MW along 200 tiles of medium poles (S2), T3 feeds 5 MW along 20 tiles (S3).
# Machines count as spread along their lines.

# %%
poles, wires = {}, []
gp, gw = m.line_poles("g", (0, 0), (-15, 0), 4, "medium")       # g0 = T1's input pole
poles.update(gp); wires += gw
tp, tw = m.line_poles("k", (0, 0), (100, 0), 5, "big")          # trunk, k0 = T1's output
poles.update(tp); wires += tw
s2p, s2w = m.line_poles("a", (106, 12), (306, 12), 23, "medium")    # S2 line from T2
s3p, s3w = m.line_poles("c", (106, -12), (126, -12), 4, "medium")   # S3 line from T3
poles.update(s2p); poles.update(s3p); wires += s2w + s3w

d_gen = m.shortest_distances(gp, gw, "g0")
d_trunk = m.shortest_distances(tp, tw, "k0")
d_s2 = m.shortest_distances(s2p, s2w, "a0")
d_s3 = m.shortest_distances(s3p, s3w, "c0")

L_gen = m.loss_from_ratio(np.mean([m.loss_ratio(m.route_loss(d_gen[f"g{k}"])) for k in (1, 2, 3)]))
L_trunk = m.route_loss(d_trunk["k4"])
L_s2 = m.loss_from_ratio(np.mean([m.loss_ratio(m.route_loss(d)) for d in d_s2.values()]))
L_s3 = m.loss_from_ratio(np.mean([m.loss_ratio(m.route_loss(d)) for d in d_s3.values()]))

t2 = m.transformer_stage(30e6, L_s2, 60e6)
t3 = m.transformer_stage(5e6, L_s3, 60e6)
t1 = m.transformer_stage(t2["draw"] + t3["draw"], L_trunk, 60e6)
gen_wires = t1["draw"] * m.loss_ratio(L_gen)
generated = t1["draw"] + gen_wires

loss_at = {}
loss_at.update({p: m.route_loss(d) * 100 for p, d in d_gen.items()})
loss_at.update({p: m.route_loss(d) * 100 for p, d in d_trunk.items()})
loss_at.update({p: m.route_loss(d) * 100 for p, d in d_s2.items()})
loss_at.update({p: m.route_loss(d) * 100 for p, d in d_s3.items()})

draw_poles = dict(poles)
draw_poles["T1"] = (0, 0, "big")
draw_poles["T2"] = (100, 12, "medium")
draw_poles["T3"] = (100, -12, "medium")
draw_wires = wires + [("k4", "T2"), ("k4", "T3"), ("T2", "a0"), ("T3", "c0")]
labels = {"g3": f"G1-G3: d {d_gen['g1']:.0f} / {d_gen['g2']:.0f} / {d_gen['g3']:.0f}",
          "k2": f"d {d_trunk['k2']:.0f}", "k4": f"d {d_trunk['k4']:.0f}",
          "a11": f"d {d_s2['a11']:.0f}", "a22": f"d {d_s2['a22']:.0f}", "c3": f"d {d_s3['c3']:.0f}"}

fig, (ax, bx) = plt.subplots(2, 1, figsize=(14, 9), gridspec_kw={"height_ratios": [0.8, 1.3]})
m.draw_network(ax, draw_poles, draw_wires, values=loss_at, vmin=0, vmax=12,
               transformers=["T1", "T2", "T3"], labels=labels,
               title="Route loss at each pole, from the transformer feeding it (%)",
               colorbar_label="route loss (%)", shape_legend=True)
ax.set_aspect("auto")      # stretch vertically: the grid is long and thin
ax.set_ylim(-26, 30)
ax.annotate(f"T1: upstream {L_gen * 100:.2f}%, downstream {L_trunk * 100:.2f}%", (10, -9), fontsize=8)
ax.annotate(f"T2: downstream {L_s2 * 100:.2f}% (S2, 30 MW)", (180, 20), fontsize=8)
ax.annotate(f"T3: downstream {L_s3 * 100:.2f}% (S3, 5 MW)", (135, -14), fontsize=8)

steps = [("generator wires", gen_wires),
         ("T1 ineff. + core", t1["ineff"] + t1["core"]),
         ("trunk", t1["line"]),
         ("T2 ineff. + core", t2["ineff"] + t2["core"]),
         ("T3 ineff. + core", t3["ineff"] + t3["core"]),
         ("S2 line", t2["line"]),
         ("S3 line", t3["line"])]
waterfall(bx, generated, steps, 35e6,
          f"From {generated / 1e6:.2f} MW generated to 35 MW at the machines "
          f"({(generated - 35e6) / generated * 100:.1f}% lost)")
plt.tight_layout()
plt.show()

# %% [markdown]
# The map shows where the distance builds up: the 100-tile big-pole trunk ends at d = 100 (2.5%),
# while S2's medium line reaches d = 447 at its far end (11.2%), so S2's line is the biggest single
# loss even though it is only twice as long as the trunk. (The model counts S2's 23 real poles, so it
# gives 5.71% where the FAQ's idealised continuous line gives 5.70%.)


# %% [markdown]
# ## 10. A bigger base: a plant, a trunk, two branches and an outpost
#
# The same analysis on a base with four transformers and five networks:
#
# * a **steam field** of 15 substations (120 MW of engines, 8 MW per substation) collected by T1;
# * a **huge-pole trunk**, 850 tiles, carrying everything east;
# * **T2** at the end of the trunk, feeding a 90 × 72-tile substation block (60 MW of machines);
# * **T3** branching off the trunk two thirds of the way along, feeding a 300-tile substation line
#   with 30 MW of machines spread along it, and at its end the input of **T4**;
# * **T4**, an outpost transformer, feeding a small medium-pole block (10 MW).
#
# Each transformer's downstream line loss is the L / (1 − L) average over its own network's routes,
# weighted by the power each consumer draws; T1's two routes are the inputs of T2 and T3, so the
# split between the branches decides its average.

# %%
# --- the five networks -------------------------------------------------------------------------
coll, coll_w = m.grid_poles("c", 0, -18, 5, 3, 18, "substation")          # steam field
trunk, trunk_w = m.line_poles("k", (110, 0), (960, 0), 16, "huge")        # trunk
f1, f1_w = m.grid_poles("b", 1000, -36, 6, 5, 18, "substation")           # T2's block
line3, line3_w = m.line_poles("e", (700, -110), (1000, -110), 18, "substation")   # T3's line
f2, f2_w = m.grid_poles("n", 1040, -131, 6, 4, 7, "medium")               # T4's block

T = {"T1": (90, 0, "substation"), "T2": (980, 0, "huge"),
     "T3": (677, -55, "huge"), "T4": (1020, -110, "substation")}

net_gen = {**coll, "T1": T["T1"]}
net_gen_w = coll_w + [("T1", "c2_1")]
net_trunk = {**trunk, **{k: T[k] for k in ("T1", "T2", "T3")}}
net_trunk_w = trunk_w + [("T1", "k0"), ("k15", "T2"), ("k10", "T3")]
net_f1 = {**f1, "T2": T["T2"]}
net_f1_w = f1_w + [("T2", "b0_2")]
net_3 = {**line3, "T3": T["T3"], "T4": T["T4"]}
net_3_w = line3_w + [("T3", "e0"), ("e17", "T4")]
net_f2 = {**f2, "T4": T["T4"]}
net_f2_w = f2_w + [("T4", "n0_1")]

d_gen = m.shortest_distances(net_gen, net_gen_w, "T1")
d_trunk = m.shortest_distances(net_trunk, net_trunk_w, "T1")
d_f1 = m.shortest_distances(net_f1, net_f1_w, "T2")
d_3 = m.shortest_distances(net_3, net_3_w, "T3")
d_f2 = m.shortest_distances(net_f2, net_f2_w, "T4")

# --- the losses, worked out from the machines back to the engines ------------------------------
SUB, MED, HUGE = m.RATINGS["substation"], m.RATINGS["medium"], m.RATINGS["huge"]

L4 = transformer_loss(d_f2, f2)                                   # T4 -> outpost machines
t4 = m.transformer_stage(10e6, L4, rating=min(SUB, MED))

share3 = 30e6 / len(line3)                                        # machines along T3's line
g3 = (sum(share3 * m.loss_ratio(m.route_loss(d_3[p])) for p in line3)
      + t4["draw"] * m.loss_ratio(m.route_loss(d_3["T4"]))) / (30e6 + t4["draw"])
L3 = m.loss_from_ratio(g3)
t3 = m.transformer_stage(30e6 + t4["draw"], L3, rating=min(HUGE, SUB))

L2 = transformer_loss(d_f1, f1)                                   # T2 -> its block
t2 = m.transformer_stage(60e6, L2, rating=min(HUGE, SUB))

g1 = (t2["draw"] * m.loss_ratio(m.route_loss(d_trunk["T2"]))
      + t3["draw"] * m.loss_ratio(m.route_loss(d_trunk["T3"]))) / (t2["draw"] + t3["draw"])
L1 = m.loss_from_ratio(g1)
t1 = m.transformer_stage(t2["draw"] + t3["draw"], L1, rating=min(SUB, HUGE))

L_gen = transformer_loss(d_gen, coll)                             # engines -> T1
gen_wires = t1["draw"] * m.loss_ratio(L_gen)
generated = t1["draw"] + gen_wires
MACHINES = 100e6

# --- the map -----------------------------------------------------------------------------------
poles = {**coll, **trunk, **f1, **line3, **f2, **T}
wires = coll_w + trunk_w + f1_w + line3_w + f2_w + [
    ("T1", "c2_1"), ("T1", "k0"), ("k15", "T2"), ("k10", "T3"), ("T2", "b0_2"),
    ("T3", "e0"), ("e17", "T4"), ("T4", "n0_1")]
loss_at = {}
for d, group in [(d_gen, coll), (d_trunk, trunk), (d_f1, f1), (d_3, line3), (d_f2, f2)]:
    loss_at.update({p: m.route_loss(d[p]) * 100 for p in group})

fig, ax = plt.subplots(figsize=(15, 5))
m.draw_network(ax, poles, wires, values=loss_at, vmin=0, vmax=12, transformers=list(T),
               labels={"k8": f"d {d_trunk['k8']:.0f}", "e9": f"d {d_3['e9']:.0f}",
                       "b5_4": f"d {d_f1['b5_4']:.0f}", "n5_3": f"d {d_f2['n5_3']:.0f}"},
               label_size=8, colorbar_label="route loss (%)", shape_legend=True,
               title="Route loss at each pole, from the transformer feeding it")
ax.set_aspect("auto")          # 1,100 tiles wide against 170 tall: stretch the short axis
ax.set_ylim(-190, 90)
for name, (label, dx, dy) in {
        "T1": (f"T1: upstream {L_gen * 100:.2f}%, downstream {L1 * 100:.2f}%", -60, 40),
        "T2": (f"T2: downstream {L2 * 100:.2f}%\n(60 MW block)", -40, 40),
        "T3": (f"T3: downstream {L3 * 100:.2f}%\n(30 MW line + T4)", -170, 20),
        "T4": (f"T4: downstream {L4 * 100:.2f}%\n(10 MW outpost)", -30, -60)}.items():
    ax.annotate(label, (poles[name][0] + dx, poles[name][1] + dy), fontsize=8)
plt.show()

steps = [("generator wires", gen_wires),
         ("T1 ineff. + core", t1["ineff"] + t1["core"]),
         ("trunk (T1)", t1["line"]),
         ("T2 ineff. + core", t2["ineff"] + t2["core"]),
         ("T2's block", t2["line"]),
         ("T3 ineff. + core", t3["ineff"] + t3["core"]),
         ("T3's line", t3["line"]),
         ("T4 ineff. + core", t4["ineff"] + t4["core"]),
         ("outpost block", t4["line"])]
fig, bx = plt.subplots(figsize=(11, 4.6))
waterfall(bx, generated, steps, MACHINES,
          f"From {generated / 1e6:.1f} MW generated to {MACHINES / 1e6:.0f} MW at the machines "
          f"({(generated - MACHINES) / generated * 100:.1f}% lost)")
plt.tight_layout()
plt.show()

total = sum(v for _, v in steps)
print(f"check: {generated / 1e6:.3f} MW generated - {total / 1e6:.3f} MW lost "
      f"= {(generated - total) / 1e6:.3f} MW at the machines")
print("\nthe losses, largest first:")
for name, v in sorted(steps, key=lambda kv: -kv[1]):
    print(f"  {name:<20}{v / 1e6:6.2f} MW   {v / total * 100:4.1f}% of all losses")
print()
# Each transformer's upstream figure is built from the route that reaches it, not from its
# feeder's downstream average: T2 and T3 hang off the same trunk at different distances.
up_T2 = m.route_loss(d_trunk["T2"])
up_T3 = m.route_loss(d_trunk["T3"])
up_T4 = m.route_loss(d_3["T4"])
print(f"{'':<4}{'upstream':>10}{'downstream':>12}{'drawn':>10}{'output':>10}{'core':>9}")
for name, up, down, st in [("T1", L_gen, L1, t1), ("T2", up_T2, L2, t2),
                           ("T3", up_T3, L3, t3), ("T4", up_T4, L4, t4)]:
    print(f"{name:<4}{up * 100:9.2f}%{down * 100:11.2f}%{st['draw'] / 1e6:9.2f}M"
          f"{st['out'] / 1e6:9.2f}M{st['core'] / 1e3:8.0f}k")

# %% [markdown]
# Reading the waterfall: the trunk is the single biggest loss, well over a third of everything lost,
# because it carries all 115 MW over 850 tiles; huge poles make that stretch cheap per tile, not
# free. T3's line loses twice what T2's block loses while delivering half the power: 30 MW spread
# along 300 tiles of substations costs far more than 60 MW inside a compact block. The outpost's own
# two losses are small in absolute terms, but they are 4% of the 10 MW it delivers, on top of the
# trunk and T3's line it has already paid for upstream.
#
# The table is what the mod's transformer panels would show. Note that a transformer's upstream
# figure is *not* its feeder's downstream figure. T1's downstream line loss is one average over both
# its routes, while T2 and T3 each read the route that reaches them: T2 sits at the end of the trunk
# and T3 two thirds of the way along, so they read different numbers, and T1's average sits between
# them. The two only coincide when a transformer feeds exactly one consumer.

# %%
