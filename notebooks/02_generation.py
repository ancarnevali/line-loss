# ---
# jupyter:
#   jupytext:
#     text_representation:
#       extension: .py
#       format_name: percent
# ---

# %% [markdown]
# # 2. Generation: from the generators to the step-up transformer
#
# A transformer fed straight by generators pays an **upstream line loss** for the wires between the
# generators and its input: every pole is weighted by the rated output of the generators in its
# supply area, and the loss is averaged as L / (1 − L) over that output. It also loses its core loss
# and inefficiency like any transformer.
#
# Two rules shape a generation layout:
#
# * **Huge poles have no supply area**, so nothing is collected on them, and these examples keep big
#   poles for transmission: the collection network is made of medium poles or substations.
# * **Power Overload limits a network to its weakest pole's rating**: a medium-pole network carries
#   at most 60 MW, a substation network 135 MW. A larger plant has to be split into several
#   collection subnets, each with its own step-up transformer into big or huge poles.
#
# 1. Collecting a steam field: medium poles or substations
# 2. Where the step-up transformer connects to the field
# 3. A large plant: how many subnets
# 4. Gathering the subnets: star or line of huge poles
# 5. A solar field: thin, spread-out generation

# %%
import numpy as np
import matplotlib.pyplot as plt

import lineloss_model as m

ENGINE = 0.9e6          # steam engine rated output (W)
PO_LIMIT = {"small": 10e6, "medium": 60e6, "substation": 135e6, "big": 300e6, "huge": 3e9}


def upstream_loss(dist, output):
    """Generation-weighted upstream line loss: L/(1-L) averaged over rated output."""
    tot = sum(output.values())
    g = sum(w * m.loss_ratio(m.route_loss(dist[p])) for p, w in output.items() if w > 0) / tot
    return m.loss_from_ratio(g)


def gens_of(poles, output, offset=3.5):
    """Small amber squares next to every generating pole (size = output)."""
    xs, ys, ss = [], [], []
    for p, w in output.items():
        if w > 0:
            xs.append(poles[p][0] + offset)
            ys.append(poles[p][1] + offset)
            ss.append(10 + w / 2e5)
    return xs, ys, ss


def draw_field(ax, poles, wires, dist, output, transformers, title, vmax=6, gens=True):
    m.draw_network(ax, poles, wires, values={p: m.route_loss(d) * 100 for p, d in dist.items()
                                             if p not in transformers},
                   vmin=0, vmax=vmax, transformers=transformers, colorbar_label="route loss (%)",
                   title=title)
    if gens:
        xs, ys, ss = gens_of(poles, output)
        ax.scatter(xs, ys, s=ss, marker="s", c="#ef9f27", edgecolor="k", linewidth=0.3, zorder=2.5)


# %% [markdown]
# ## 1. Collecting a steam field: medium poles or substations
#
# 56 steam engines (50 MW) spread over a 112 × 56-tile block, collected by a grid of medium poles
# (7 tiles apart) or of substations (18 tiles apart). Each pole collects the engines in its supply
# area (amber squares, sized by output); the transformer T connects at the west edge.

# %%
def field(kind, width=112, height=56, total=56 * ENGINE):
    sp = {"medium": 7, "substation": 18, "small": 7}[kind]
    nx, ny = int(round(width / sp)) + 1, int(round(height / sp)) + 1
    poles, wires = m.grid_poles("g", 0, 0, nx, ny, sp, kind)
    output = {p: total / len(poles) for p in poles}
    return poles, wires, output, nx, ny


fig, axes = plt.subplots(1, 2, figsize=(16, 4.2))
results = {}
for ax, kind in zip(axes, ["medium", "substation"]):
    poles, wires, output, nx, ny = field(kind)
    entry = f"g0_{ny // 2}"
    poles["T"] = (-6, poles[entry][1], kind)
    wires = wires + [("T", entry)]
    dist = m.shortest_distances(poles, wires, "T")
    results[kind] = upstream_loss(dist, output)
    draw_field(ax, poles, wires, dist, output, ["T"],
               f"{kind} collection, {len(output)} poles: upstream line loss {results[kind] * 100:.2f}%")
plt.tight_layout()
plt.show()
print({k: f"{v * 100:.2f}%" for k, v in results.items()})

# %% [markdown]
# Substations collect the same field with far fewer poles and a lower loss: their resistance is
# 1.49 against 2.24 per tile. 50 MW also fits under both Power Overload limits (60 and 135 MW).

# %% [markdown]
# ## 2. Where the step-up transformer connects to the field
#
# The substation field of section 1 with T at a corner, at the west edge, or in the middle of the
# field (with its input wired to the central substation).

# %%
fig, axes = plt.subplots(1, 3, figsize=(18, 4.2))
for ax, (name, entry_of, offset) in zip(axes, [
        ("corner", lambda nx, ny: "g0_0", (-6, -6)),
        ("west edge", lambda nx, ny: f"g0_{ny // 2}", (-6, 0)),
        ("centre", lambda nx, ny: f"g{nx // 2}_{ny // 2}", (6, 6))]):
    poles, wires, output, nx, ny = field("substation")
    entry = entry_of(nx, ny)
    poles["T"] = (poles[entry][0] + offset[0], poles[entry][1] + offset[1], "substation")
    wires = wires + [("T", entry)]
    dist = m.shortest_distances(poles, wires, "T")
    loss = upstream_loss(dist, output)
    draw_field(ax, poles, wires, dist, output, ["T"], f"T at the {name}: upstream {loss * 100:.2f}%")
plt.tight_layout()
plt.show()

# %% [markdown]
# Connecting in the middle of the field halves the generators' distance, as for a factory block.

# %% [markdown]
# ## 3. A large plant: how many subnets
#
# A 1 GW steam plant: 1,111 engines on a 420 × 210-tile site collected by substations. One
# substation network can carry at most 135 MW (Power Overload), so the plant needs at least 8
# collection subnets, each with a step-up transformer into huge poles. More subnets mean shorter
# collection routes, but every step-up transformer loses its core loss: rated by its weaker side,
# the substation side, 135 MW, so 135 kW each.

# %%
PLANT = 1e9
SITE_W, SITE_H = 420, 210


def split_plant(nx_sub, ny_sub):
    """Cut the site into nx_sub x ny_sub subnets, each a substation grid with T in its middle."""
    sub_w, sub_h = SITE_W / nx_sub, SITE_H / ny_sub
    poles, wires, output, ts, dists = {}, [], {}, [], {}
    for a in range(nx_sub):
        for b in range(ny_sub):
            nx, ny = max(2, int(round(sub_w / 18)) + 1), max(2, int(round(sub_h / 18)) + 1)
            sp_x, sp_y = sub_w / nx, sub_h / ny
            prefix = f"s{a}_{b}_"
            sub = {f"{prefix}{i}_{j}": (a * sub_w + (i + 0.5) * sp_x, b * sub_h + (j + 0.5) * sp_y, "substation")
                   for i in range(nx) for j in range(ny)}
            sw = [(f"{prefix}{i}_{j}", f"{prefix}{i + 1}_{j}") for i in range(nx - 1) for j in range(ny)]
            sw += [(f"{prefix}{i}_{j}", f"{prefix}{i}_{j + 1}") for i in range(nx) for j in range(ny - 1)]
            centre = f"{prefix}{nx // 2}_{ny // 2}"
            t = f"T{len(ts) + 1}"
            sub_poles = dict(sub)
            sub_poles[t] = (sub[centre][0] + 4, sub[centre][1] + 4, "substation")
            d = m.shortest_distances(sub_poles, sw + [(t, centre)], t)
            poles.update(sub_poles)
            wires += sw + [(t, centre)]
            ts.append(t)
            dists[t] = d
            for p in sub:
                output[p] = PLANT / (nx_sub * ny_sub) / len(sub)
    return poles, wires, output, ts, dists


def plant_losses(nx_sub, ny_sub):
    poles, wires, output, ts, dists = split_plant(nx_sub, ny_sub)
    n = len(ts)
    line = 0.0
    for t in ts:
        mine = {p: w for p, w in output.items() if p in dists[t] and p != t}
        line += sum(mine.values()) * m.loss_ratio(upstream_loss(dists[t], mine))
    core = n * min(m.RATINGS["substation"], m.RATINGS["huge"]) * m.CORE_LOSS
    return line, core, (poles, wires, output, ts, dists)


splits = [(1, 1), (2, 1), (2, 2), (4, 2), (4, 4), (8, 4), (8, 8)]
rows = []
for sx, sy in splits:
    line, core, _ = plant_losses(sx, sy)
    rows.append((sx * sy, line, core))

fig, axes = plt.subplots(1, 3, figsize=(18, 4.4))
for ax, (sx, sy) in zip(axes, [(1, 1), (4, 2), (8, 4)]):
    line, core, (poles, wires, output, ts, dists) = plant_losses(sx, sy)
    dist = {}
    for t in ts:
        dist.update({p: v for p, v in dists[t].items()})
    draw_field(ax, poles, wires, dist, output, ts if len(ts) <= 8 else [],
               f"{sx * sy} subnet{'s' if sx * sy > 1 else ''}: upstream {line / 1e6:.1f} MW, "
               f"core {core / 1e6:.2f} MW", vmax=8, gens=False)
    if len(ts) > 8:
        ax.scatter([poles[t][0] for t in ts], [poles[t][1] for t in ts], s=50, marker="s",
                   c="#1d9e75", edgecolor="k", zorder=3)
plt.tight_layout()
plt.show()

fig, ax = plt.subplots(figsize=(8, 3.8))
xs = np.arange(len(rows))
ax.bar(xs - 0.2, [r[1] / 1e6 for r in rows], 0.4, color="#7f8c8d", label="upstream line loss (collection)")
ax.bar(xs + 0.2, [r[2] / 1e6 for r in rows], 0.4, color="#1d9e75", label="core loss (step-up transformers)")
tot = [(r[1] + r[2]) / 1e6 for r in rows]
ax.plot(xs, tot, "o-", color="#d85a30", label="total")
ax.axvspan(-0.5, 2.5, color="#e24b4a", alpha=0.08)
ax.text(1, max(tot) * 0.92, "over 135 MW per subnet:\nsubstations overload", ha="center", fontsize=8,
        color="#a32d2d")
ax.set_xticks(xs, [str(r[0]) for r in rows])
ax.set_xlabel("collection subnets (each with its own step-up transformer)")
ax.set_ylabel("MW lost collecting 1 GW")
ax.set_title("A 1 GW plant: split it, the more the better until core loss catches up")
ax.legend(fontsize=8)
plt.show()
#AC here is where I see that core loss is probably nerfed. No changes for now, but keep in mind for balancing
# %% [markdown]
# Even ignoring Power Overload's limit (1 to 4 subnets would overload the substations), one network
# spanning the whole site loses the most. With 8 to 32 subnets each transformer sits in the middle of
# a small patch, so collection is cheap, and 135 kW of core loss per transformer stays small next to
# a gigawatt; at 64 subnets core loss starts to cost more than it saves.

# %% [markdown]
# ## 4. Gathering the subnets: star or line of huge poles
#
# The 8 step-up transformers of section 3 feed a huge-pole network leading to the main transmission
# line at the east end of the site. Their **downstream** line loss is the distance along the huge
# poles to the transmission transformer X. A line of huge poles along the site, or a star with a
# huge pole run from each transformer straight to X.

# %%
line_out, core_out, (poles, wires, output, ts, dists) = plant_losses(4, 2)
tpos = {t: poles[t][:2] for t in ts}
X = (SITE_W + 60, SITE_H / 2)
fig, axes = plt.subplots(1, 2, figsize=(16, 4.6))
for ax, layout in zip(axes, ["line", "star"]):
    hp = {"X": (X[0], X[1], "huge")}
    hw = []
    if layout == "line":
        spine = {f"h{k}": (x, SITE_H / 2, "huge") for k, x in enumerate(np.linspace(0, SITE_W + 30, 8))}
        hp.update(spine)
        hw += [(f"h{k}", f"h{k + 1}") for k in range(7)] + [("h7", "X")]
        for t, (x, y) in tpos.items():
            k = int(np.argmin([abs(spine[f"h{j}"][0] - x) for j in range(8)]))
            hp[t] = (x, y, "huge")
            hw.append((t, f"h{k}"))
    else:
        for t, (x, y) in tpos.items():
            hp[t] = (x, y, "huge")
            hw.append((t, "X"))
    d = {t: m.shortest_distances(hp, hw, t)["X"] for t in ts}
    share = PLANT / len(ts)
    burn = sum(share * m.loss_ratio(m.route_loss(d[t])) for t in ts)
    m.draw_network(ax, hp, hw, transformers=ts + ["X"],
                   labels={t: f"d {d[t]:.0f}" for t in ts},
                   title=f"{layout}: downstream line loss {burn / 1e6:.1f} MW "
                         f"({burn / PLANT * 100:.2f}% of 1 GW)")
plt.tight_layout()
plt.show()

# %% [markdown]
# Huge poles cost 0.32 per tile, so even a few hundred tiles of gathering lines cost little. The star
# is slightly cheaper because every transformer has a straight run to X, but a single line along the
# site needs much less huge-pole cable for almost the same loss.

# %% [markdown]
# ## 5. A solar field: thin, spread-out generation
#
# 50 MW of solar is a much bigger area than 50 MW of steam: about 830 panels plus accumulators,
# roughly 250 × 250 tiles. Spread over a large area, the generation-weighted distance is long, so
# collection loss matters more. The same field collected by one transformer at its edge, one in its
# middle, or four transformers, each in the middle of a quarter.

# %%
def solar(n_side_tx):
    size = 252
    sub = size / n_side_tx
    poles, wires, output, ts, dists = {}, [], {}, [], {}
    for a in range(n_side_tx):
        for b in range(n_side_tx):
            nx = int(round(sub / 18)) + 1
            sp = sub / nx
            prefix = f"q{a}_{b}_"
            q = {f"{prefix}{i}_{j}": (a * sub + (i + 0.5) * sp, b * sub + (j + 0.5) * sp, "substation")
                 for i in range(nx) for j in range(nx)}
            qw = [(f"{prefix}{i}_{j}", f"{prefix}{i + 1}_{j}") for i in range(nx - 1) for j in range(nx)]
            qw += [(f"{prefix}{i}_{j}", f"{prefix}{i}_{j + 1}") for i in range(nx) for j in range(nx - 1)]
            poles.update(q)
            wires += qw
            for p in q:
                output[p] = 50e6 / (n_side_tx ** 2) / len(q)
            centre = f"{prefix}{nx // 2}_{nx // 2}"
            ts.append((f"T{len(ts) + 1}", centre, q))
    return poles, wires, output, ts


fig, axes = plt.subplots(1, 3, figsize=(18, 5.2))
for ax, (label, n_side, at_edge) in zip(axes, [("one T at the edge", 1, True),
                                               ("one T in the middle", 1, False),
                                               ("four T, one per quarter", 2, False)]):
    poles, wires, output, ts = solar(n_side)
    all_d, burn, names = {}, 0.0, []
    for t, centre, q in ts:
        if at_edge:
            ny = int(round(np.sqrt(len(q))))
            centre = f"q0_0_0_{ny // 2}"
            poles[t] = (poles[centre][0] - 8, poles[centre][1], "substation")
        else:
            poles[t] = (poles[centre][0] + 5, poles[centre][1] + 5, "substation")
        wires = wires + [(t, centre)]
        d = m.shortest_distances({**q, t: poles[t]}, [w for w in wires if w[0] in q or w[0] == t], t)
        all_d.update(d)
        mine = {p: output[p] for p in q}
        burn += sum(mine.values()) * m.loss_ratio(upstream_loss(d, mine))
        names.append(t)
    core = len(ts) * m.RATINGS["substation"] * m.CORE_LOSS
    draw_field(ax, poles, wires, all_d, output, names,
               f"{label}: upstream {burn / 1e6:.2f} MW, core {core / 1e6:.2f} MW", vmax=8)
plt.tight_layout()
plt.show()

# %% [markdown]
# Spread over 250 × 250 tiles, even 50 MW loses 7.7% with the transformer at the edge. Moving it to
# the middle saves a third; four transformers, each in the middle of a quarter, halve it again for
# 0.4 MW of extra core loss.
