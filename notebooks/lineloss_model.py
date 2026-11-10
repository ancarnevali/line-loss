"""Small Python re-implementation of the Line loss mod's model, for the example notebooks.

It mirrors the mod's formulas (scripts/line-losses.lua, scripts/transformers.lua) with the default
settings. It is a teaching model: no Factorio API, no scheduling, no smoothing.
"""
import heapq
import math

import numpy as np

# --- Settings (mod defaults) ---------------------------------------------------------------
PER_TILE = 0.025 / 100      # line loss per tile of resistance-weighted distance
CAP = 0.95                  # per-route cap
EFFICIENCY = 0.99           # transformer efficiency
CORE_LOSS = 0.1 / 100       # of the transformer's rating, while switched on

# Power Overload default ratings (W)
RATINGS = {
    "small": 10e6,
    "medium": 60e6,
    "substation": 135e6,
    "big": 300e6,
    "huge": 3e9,
}


def resistance(pole_type):
    """Resistance per tile, big pole = 1: r = sqrt(P_big / P_pole)."""
    return math.sqrt(RATINGS["big"] / RATINGS[pole_type])


def wire_cost(length, type_a, type_b):
    """Resistance-weighted length of one wire."""
    return length * (resistance(type_a) + resistance(type_b)) / 2


def route_loss(d):
    """Loss of one route of resistance-weighted distance d, capped per route."""
    return min(PER_TILE * d, CAP)


def shortest_distances(poles, wires, start):
    """Dijkstra over a pole graph.

    poles: {name: (x, y, pole_type)}; wires: [(a, b)]; start: pole name.
    Returns {name: resistance-weighted distance}.
    """
    adjacency = {p: [] for p in poles}
    for a, b in wires:
        (xa, ya, ta), (xb, yb, tb) = poles[a], poles[b]
        w = wire_cost(math.hypot(xb - xa, yb - ya), ta, tb)
        adjacency[a].append((b, w))
        adjacency[b].append((a, w))
    dist = {start: 0.0}
    heap = [(0.0, start)]
    done = set()
    while heap:
        d, p = heapq.heappop(heap)
        if p in done:
            continue
        done.add(p)
        for q, w in adjacency[p]:
            nd = d + w
            if q not in dist or nd < dist[q]:
                dist[q] = nd
                heapq.heappush(heap, (nd, q))
    return dist


def transformer_stage(load_out, loss, rating):
    """One transformer feeding `load_out` (W) over wires losing `loss`.

    Returns a dict with output, line loss charged downstream, inefficiency and core loss charged
    upstream, and the total drawn from the upstream network.
    """
    out = load_out / (1 - loss)                 # line loss = out * loss, so delivered = out * (1 - loss)
    line = out - load_out
    ineff = out * (1 - EFFICIENCY) / EFFICIENCY
    core = rating * CORE_LOSS
    return {"out": out, "line": line, "ineff": ineff, "core": core, "draw": out + ineff + core}


def sinkhorn(K, supply, demand, iterations=200):
    """Balance flows f = a K b so rows sum to supply and columns to demand.

    K: (sources x consumers) pull matrix (1/d), zeros for dropped pairs.
    """
    K = np.asarray(K, float)
    supply = np.asarray(supply, float)
    demand = np.asarray(demand, float) * supply.sum() / np.asarray(demand, float).sum()
    a = np.ones(K.shape[0])
    b = np.ones(K.shape[1])
    for _ in range(iterations):
        a = supply / np.maximum(K @ b, 1e-12)
        b = demand / np.maximum(K.T @ a, 1e-12)
    return a[:, None] * K * b[None, :]


def loss_ratio(loss):
    """Power lost per unit delivered on a route: L / (1 - L)."""
    return loss / (1 - loss)


def loss_from_ratio(ratio):
    """Back from an averaged ratio to the share of output lost."""
    return ratio / (1 + ratio)


def weighted_route_loss(flows, distances):
    """Each source's loss: L / (1 - L) averaged over its capped routes, weighted by the power each
    delivers, turned back into a share of output. Delivered x average ratio = the sum of every
    route's loss exactly (averaging L itself would under-charge mixed routes)."""
    losses = np.vectorize(route_loss)(np.asarray(distances, float))
    flows = np.asarray(flows, float)
    return loss_from_ratio((flows * loss_ratio(losses)).sum(axis=1) / flows.sum(axis=1))


def spread_line_loss(length, resistance_factor, n=1001):
    """Loss of machines spread evenly along a line: every pole's route counts equally."""
    d = np.linspace(0, length * resistance_factor, n)
    return loss_from_ratio(loss_ratio(np.vectorize(route_loss)(d)).mean())


# --- Network drawing ------------------------------------------------------------------------
POLE_STYLE = {   # marker size, wire colour, wire width, marker shape
    "small": (18, "#b08968", 0.8, "v"),
    "medium": (28, "#7f8c8d", 1.2, "o"),
    "substation": (60, "#5d6d7e", 1.6, "^"),
    "big": (45, "#2e4053", 2.2, "D"),
    "huge": (70, "#17202a", 3.2, "H"),
}


def grid_poles(prefix, x0, y0, nx, ny, spacing, pole_type):
    """A rectangular block of poles, wired to their right and lower neighbours."""
    poles, wires = {}, []
    for i in range(nx):
        for j in range(ny):
            poles[f"{prefix}{i}_{j}"] = (x0 + i * spacing, y0 + j * spacing, pole_type)
            if i > 0:
                wires.append((f"{prefix}{i - 1}_{j}", f"{prefix}{i}_{j}"))
            if j > 0:
                wires.append((f"{prefix}{i}_{j - 1}", f"{prefix}{i}_{j}"))
    return poles, wires


def line_poles(prefix, start, end, n, pole_type):
    """n poles evenly spaced from start to end (inclusive), wired in a chain."""
    (xa, ya), (xb, yb) = start, end
    poles = {f"{prefix}{k}": (xa + (xb - xa) * k / (n - 1), ya + (yb - ya) * k / (n - 1), pole_type)
             for k in range(n)}
    wires = [(f"{prefix}{k - 1}", f"{prefix}{k}") for k in range(1, n)]
    return poles, wires


def draw_network(ax, poles, wires, values=None, cmap="RdYlGn_r", vmin=None, vmax=None,
                 labels=None, label_size=7, transformers=(), title=None, colorbar_label=None,
                 sizes=None, pole_colours=None, shape_legend=False):
    """Draw poles and wires to scale (tiles).

    values: {pole: number} colours the poles (e.g. distance or loss); labels: {pole: text};
    sizes: {pole: marker size}; pole_colours: {pole: colour} overrides values;
    transformers: pole names drawn as transformers (green squares).

    Each pole type gets its own marker shape: small a triangle down, medium a circle, substation a
    triangle up, big a diamond, huge a hexagon. shape_legend adds a key for the types present.
    """
    import matplotlib.pyplot as plt
    for a, b in wires:
        (xa, ya, ta), (xb, yb, tb) = poles[a], poles[b]
        t = ta if resistance(ta) >= resistance(tb) else tb   # wire drawn as its thinner pole
        _, colour, width, _m = POLE_STYLE[t]
        ax.plot([xa, xb], [ya, yb], color=colour, lw=width, zorder=1, solid_capstyle="round")
    names = [p for p in poles if p not in transformers]
    by_type = {}
    for p in names:
        by_type.setdefault(poles[p][2], []).append(p)
    sc = None
    for kind, group in by_type.items():
        marker = POLE_STYLE[kind][3]
        xs = [poles[p][0] for p in group]
        ys = [poles[p][1] for p in group]
        s = [(sizes or {}).get(p, POLE_STYLE[kind][0]) for p in group]
        if pole_colours:
            ax.scatter(xs, ys, s=s, marker=marker, c=[pole_colours.get(p, "#cccccc") for p in group],
                       edgecolor="k", linewidth=0.4, zorder=2)
        elif values is not None:
            c = [values.get(p, np.nan) for p in group]
            sc = ax.scatter(xs, ys, s=s, marker=marker, c=c, cmap=cmap, vmin=vmin, vmax=vmax,
                            edgecolor="k", linewidth=0.4, zorder=2)
        else:
            ax.scatter(xs, ys, s=s, marker=marker, c="white", edgecolor="k", linewidth=0.6, zorder=2)
    for t in transformers:
        ax.scatter([poles[t][0]], [poles[t][1]], s=160, marker="s", c="#1d9e75", edgecolor="k",
                   zorder=3)
        ax.annotate(t, (poles[t][0], poles[t][1]), textcoords="offset points", xytext=(0, 9),
                    ha="center", fontsize=8, weight="bold", zorder=4)
    for p, text in (labels or {}).items():
        ax.annotate(text, (poles[p][0], poles[p][1]), textcoords="offset points", xytext=(0, -11),
                    ha="center", fontsize=label_size, zorder=4)
    ax.set_aspect("equal")
    ax.set_xlabel("tiles")
    ax.margins(0.08)
    if title:
        ax.set_title(title)
    if shape_legend:
        handles = [plt.Line2D([], [], marker=POLE_STYLE[k][3], color="none", markerfacecolor="#d3d1c7",
                              markeredgecolor="k", markersize=np.sqrt(POLE_STYLE[k][0]) + 2, label=k)
                   for k in ("small", "medium", "substation", "big", "huge") if k in by_type]
        if transformers:
            handles.append(plt.Line2D([], [], marker="s", color="none", markerfacecolor="#1d9e75",
                                      markeredgecolor="k", markersize=10, label="transformer"))
        ax.legend(handles=handles, fontsize=8, loc="best", framealpha=0.9)
    if sc is not None and colorbar_label:
        plt.colorbar(sc, ax=ax, label=colorbar_label, shrink=0.8)
    return sc


def ownership(dist_by_source):
    """Owner of every pole: the source with the shortest distance (ties: first listed)."""
    sources = list(dist_by_source)
    poles = dist_by_source[sources[0]].keys()
    return {p: min(sources, key=lambda s: dist_by_source[s].get(p, math.inf)) for p in poles}
