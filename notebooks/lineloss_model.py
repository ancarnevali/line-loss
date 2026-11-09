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

    Returns a dict with output, line loss burned downstream, inefficiency and core loss burned
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


def weighted_route_loss(flows, distances):
    """Each source's loss: flow-weighted average of its capped route losses."""
    losses = np.vectorize(route_loss)(np.asarray(distances, float))
    flows = np.asarray(flows, float)
    return (flows * losses).sum(axis=1) / flows.sum(axis=1)
