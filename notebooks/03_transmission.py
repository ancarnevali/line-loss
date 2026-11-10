# ---
# jupyter:
#   jupytext:
#     text_representation:
#       extension: .py
#       format_name: percent
# ---

# %% [markdown]
# # 3. Long-range transmission
#
# Between the step-up transformer at a plant and the step-down transformers at the factories, power
# travels on big or huge poles. The step-up transformer pays this stretch as its **downstream line
# loss**: 0.025% per tile × the pole's resistance (big 1, huge 0.32), capped at 95% per route.
#
# Power Overload limits each network to its weakest pole's rating: 300 MW on big poles, 3 GW on huge
# poles.
#
# 1. How far each pole type can carry power
# 2. 1 GW over 1,500 tiles: one huge line or four big lines
# 3. Repeater transformers on a very long line
# 4. Three factories: separate lines or one trunk with branches

# %%
import numpy as np
import matplotlib.pyplot as plt

import lineloss_model as m

PO_LIMIT = {"small": 10e6, "medium": 60e6, "substation": 135e6, "big": 300e6, "huge": 3e9}
COLOURS = {"small": "#b08968", "medium": "#7f8c8d", "substation": "#5d6d7e", "big": "#2e4053",
           "huge": "#17202a"}

# %% [markdown]
# ## 1. How far each pole type can carry power

# %%
tiles = np.linspace(0, 6000, 400)
fig, axes = plt.subplots(1, 2, figsize=(14, 4))
for kind in ["small", "medium", "substation", "big", "huge"]:
    r = m.resistance(kind)
    axes[0].plot(tiles, [m.route_loss(t * r) * 100 for t in tiles], color=COLOURS[kind], lw=2,
                 label=f"{kind} (r = {r:.2f})")
axes[0].set_xlabel("map length of the line (tiles)")
axes[0].set_ylabel("route loss (%)")
axes[0].set_title("Loss along a straight line (capped at 95%)")
axes[0].legend()

kinds = ["small", "medium", "substation", "big", "huge"]
x = np.arange(len(kinds))
for i, (pct, col) in enumerate(zip((1, 5, 10), ["#9fe1cb", "#1d9e75", "#085041"])):
    axes[1].bar(x + (i - 1) * 0.27, [pct / 0.025 / m.resistance(k) for k in kinds], 0.27,
                color=col, label=f"{pct}% lost")
axes[1].set_xticks(x, kinds)
axes[1].set_yscale("log")
axes[1].set_ylabel("tiles")
axes[1].set_title("How far until 1%, 5% or 10% is lost")
axes[1].legend()
plt.tight_layout()
plt.show()
for k in kinds:
    print(f"{k:>10}: 10% lost after {10 / 0.025 / m.resistance(k):6.0f} tiles, "
          f"Power Overload limit {PO_LIMIT[k] / 1e6:6.0f} MW")

# %% [markdown]
# Huge poles carry power three times as far as big poles for the same loss, and ten times as much
# power. Medium poles and below are for the last few hundred tiles only.

# %% [markdown]
# ## 2. 1 GW over 1,500 tiles: one huge line or four big lines
#
# One huge-pole line carries the whole gigawatt. Big poles are limited to 300 MW per network, so the
# same power needs four separate big-pole lines, each with its own step-up and step-down
# transformers. (Parallel wires in one network would not help anyway: the mod counts the shortest
# path, not parallel paths.)

# %%
LENGTH = 1500
POWER = 1e9


def straight(prefix, y, kind, spacing):
    n = int(LENGTH // spacing) + 1
    return m.line_poles(prefix, (0, y), (LENGTH, y), n, kind)


fig, axes = plt.subplots(2, 1, figsize=(15, 5.5))
cases = {}
hp, hw = straight("h", 0, "huge", 60)
hp = {("A" if k == "h0" else "B" if k == f"h{len(hp) - 1}" else k): v for k, v in hp.items()}
hw = [tuple("A" if p == "h0" else "B" if p == f"h{len(hp) - 1}" else p for p in w) for w in hw]
d_h = m.shortest_distances(hp, hw, "A")
m.draw_network(axes[0], hp, hw, values={p: m.route_loss(d) * 100 for p, d in d_h.items()},
               vmin=0, vmax=40, transformers=["A", "B"], colorbar_label="route loss (%)",
               labels={p: f"{d_h[p]:.0f}" for p in list(hp)[::5] if p not in ("A", "B")})
L_h = m.route_loss(d_h["B"])
cases["1 huge line"] = (POWER * m.loss_ratio(L_h), 2 * min(m.RATINGS["huge"], m.RATINGS["substation"]) * m.CORE_LOSS)
axes[0].set_title(f"one huge line: d = {d_h['B']:.0f}, loss {L_h * 100:.1f}%")
axes[0].set_aspect("auto")
axes[0].set_ylim(-20, 20)

bp, bw = {}, []
for k in range(4):
    p_, w_ = straight(f"b{k}_", k * 12, "big", 30)
    last = f"b{k}_{len(p_) - 1}"
    ren = {f"b{k}_0": f"A{k + 1}", last: f"B{k + 1}"}
    bp.update({ren.get(a, a): v for a, v in p_.items()})
    bw += [tuple(ren.get(p, p) for p in w) for w in w_]
d_b = {}
for k in range(1, 5):
    d_b.update(m.shortest_distances(bp, bw, f"A{k}"))
m.draw_network(axes[1], bp, bw, values={p: m.route_loss(d) * 100 for p, d in d_b.items()},
               vmin=0, vmax=40, transformers=[f"A{k}" for k in range(1, 5)] + [f"B{k}" for k in range(1, 5)],
               colorbar_label="route loss (%)")
L_b = m.route_loss(d_b["B1"])
cases["4 big lines"] = (POWER * m.loss_ratio(L_b), 8 * min(m.RATINGS["big"], m.RATINGS["substation"]) * m.CORE_LOSS)
axes[1].set_title(f"four big lines (300 MW limit each): d = {d_b['B1']:.0f}, loss {L_b * 100:.1f}%")
axes[1].set_aspect("auto")
axes[1].set_ylim(-10, 50)
plt.tight_layout()
plt.show()

for name, (line, core) in cases.items():
    print(f"{name}: downstream line loss {line / 1e6:6.1f} MW, core loss {core / 1e6:.2f} MW "
          f"(transformers rated by their substation side)")

# %% [markdown]
# Delivering 1 GW over 1,500 tiles costs 135 MW on huge poles and 600 MW on big poles: the big
# lines have to be sent 1.6 GW to deliver 1 GW. Long range is huge-pole work.

# %% [markdown]
# ## 3. Repeater transformers on a very long line
#
# A route's loss grows with distance without limit, but a *share* cannot: each stage can only take a
# share of what reaches it, so losing 20% four times over leaves 41%, not nothing. Cutting a long
# line into segments with a transformer between each pair turns one big loss into several small ones
# that compound instead of adding up.
#
# Over 8,000 tiles of huge poles one network loses 63%. Four segments of 2,000 tiles lose 15.8% each,
# and 0.842 to the fourth power is 50%, so half arrives instead of a third. Each repeater charges 1%
# inefficiency and its core loss, which is 3 MW with huge poles on both sides, so repeaters only pay
# on lines long enough for the compounding to beat that.
# %%
def delivered_share(total_tiles, k, power=1e9):
    """Share of the sent power that arrives through k segments, with k-1 repeaters."""
    L = m.route_loss(total_tiles / k * m.resistance("huge"))
    share = (1 - L) ** k * m.EFFICIENCY ** (k - 1)
    core = (k - 1) * m.RATINGS["huge"] * m.CORE_LOSS
    return share - core / power


lengths = [2000, 4000, 8000, 12000]
ks = np.arange(1, 9)
fig, axes = plt.subplots(1, 2, figsize=(14, 4))
for length in lengths:
    lost = [(1 - delivered_share(length, k)) * 100 for k in ks]
    axes[0].plot(ks, lost, "o-", label=f"{length} tiles")
    best = ks[int(np.argmin(lost))]
    axes[0].plot(best, min(lost), "*", ms=14, color="#d85a30")
axes[0].set_xlabel("segments (k − 1 repeater transformers)")
axes[0].set_ylabel("lost delivering 1 GW (%)")
axes[0].set_title("Huge line, 1 GW: lost against number of segments")
axes[0].legend()

poles, wires = {}, []
k = 3
seg = 4000 / k
for s_ in range(k):
    p_, w_ = m.line_poles(f"s{s_}_", (s_ * seg, 0), ((s_ + 1) * seg, 0), int(seg // 60) + 1, "huge")
    ren = {f"s{s_}_0": f"R{s_}" if s_ else "A", f"s{s_}_{len(p_) - 1}": f"R{s_ + 1}" if s_ < k - 1 else "B"}
    poles.update({ren.get(a, a): v for a, v in p_.items()})
    wires += [tuple(ren.get(p, p) for p in w) for w in w_]
dist = {}
for s_ in range(k):
    start = "A" if s_ == 0 else f"R{s_}"
    d = m.shortest_distances(poles, [w for w in wires if any(q.startswith(f"s{s_}_") or q == start
                                                           for q in w)], start)
    dist.update({p: v for p, v in d.items() if p.startswith(f"s{s_}_")})
m.draw_network(axes[1], poles, wires, values={p: m.route_loss(v) * 100 for p, v in dist.items()},
               vmin=0, vmax=12, transformers=["A", "R1", "R2", "B"], colorbar_label="route loss (%)",
               title="4,000 tiles in 3 segments: each network's distance restarts at its repeater")
axes[1].set_aspect("auto")
axes[1].set_ylim(-10, 10)
plt.tight_layout()
plt.show()

for length in lengths:
    lost = [(1 - delivered_share(length, k)) * 100 for k in ks]
    print(f"{length:>6} tiles: one segment {lost[0]:5.1f}% lost, best {ks[int(np.argmin(lost))]} "
          f"segments {min(lost):5.1f}%")

# %% [markdown]
# Up to a few thousand tiles a repeater barely pays: 1% inefficiency plus 3 MW of core loss eat the
# compounding gain. On very long lines, where a single network would lose a third or more, splitting
# it into segments saves real power. This follows directly from charging each network separately;
# it is worth knowing when balancing the mod.

# %% [markdown]
# ## 4. Three factories: separate lines or one trunk with branches
#
# A plant transformer P sends 300 MW to three factory transformers F1, F2, F3 (100 MW each) on huge
# poles. Either three separate lines straight to each factory, or one trunk with branches. One
# network with one source: P's downstream line loss is the power-weighted average over its three
# routes.

# %%
fac = {"F1": (1200, 600), "F2": (1500, 0), "F3": (1100, -700)}
fig, axes = plt.subplots(1, 2, figsize=(15, 5.5))
for ax, layout in zip(axes, ["separate lines", "trunk and branches"]):
    poles = {"P": (0, 0, "huge")}
    poles.update({f: (x, y, "huge") for f, (x, y) in fac.items()})
    wires = []
    if layout == "separate lines":
        for f, (x, y) in fac.items():
            pts, w_ = m.line_poles(f"{f}_", (0, 0), (x, y), int(np.hypot(x, y) // 60) + 1, "huge")
            ren = {f"{f}_0": "P", f"{f}_{len(pts) - 1}": f}
            poles.update({ren.get(a, a): v for a, v in pts.items() if a not in ren})
            wires += [tuple(ren.get(p, p) for p in w) for w in w_]
    else:
        hub = (900, 0)
        pts, w_ = m.line_poles("t_", (0, 0), hub, int(900 // 60) + 1, "huge")
        last = f"t_{len(pts) - 1}"
        ren = {"t_0": "P"}
        poles.update({ren.get(a, a): v for a, v in pts.items() if a != "t_0"})
        wires += [tuple(ren.get(p, p) for p in w) for w in w_]
        for f, (x, y) in fac.items():
            bp_, bw_ = m.line_poles(f"{f}_", hub, (x, y), int(np.hypot(x - hub[0], y - hub[1]) // 60) + 1, "huge")
            ren = {f"{f}_0": last, f"{f}_{len(bp_) - 1}": f}
            poles.update({ren.get(a, a): v for a, v in bp_.items() if a not in ren})
            wires += [tuple(ren.get(p, p) for p in w) for w in bw_]
    d = m.shortest_distances(poles, wires, "P")
    g = np.mean([m.loss_ratio(m.route_loss(d[f])) for f in fac])
    L = m.loss_from_ratio(g)
    cable = sum(np.hypot(poles[a][0] - poles[b][0], poles[a][1] - poles[b][1]) for a, b in wires)
    m.draw_network(ax, poles, wires, values={p: m.route_loss(v) * 100 for p, v in d.items() if p != "P"},
                   vmin=0, vmax=12, transformers=["P", *fac], colorbar_label="route loss (%)",
                   labels={f: f"d {d[f]:.0f}" for f in fac},
                   title=f"{layout}: P's downstream line loss {L * 100:.2f}% "
                         f"({300e6 * g / 1e6:.1f} MW), {cable:.0f} tiles of cable")
plt.tight_layout()
plt.show()

# %% [markdown]
# Separate lines give every factory its straight-line distance; the shared trunk makes the routes to
# F1 and F3 longer, for 5.6 MW more loss (12.4% against 10.9%), but needs 1,250 fewer tiles of cable.
# Whether that is worth it depends on how far the factories are spread around the trunk's end.

# %%
