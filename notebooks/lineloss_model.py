"""Teaching re-implementation of the Line loss mod's model (0.2.0), for the example notebooks.

It mirrors scripts/kirchhoff.lua at default settings, without scheduling, smoothing or the
mod's work budget:

* An electric network is transmission only if all its poles are transmission poles and it has no
  generators; any other network is distribution, its transmission poles included.
* Transmission networks: transmission poles (rated like a big pole or more; no supply area) and
  transformer terminals (a transformer's hidden output and input poles) are solved by Kirchhoff:
  power plays the current, wire cost (resistance-weighted length) the resistance. Losses on a
  wire grow with its load (I^2 R): a share PER_TILE x cost x (FLOOR + (1 - FLOOR) x flow / P_ref)
  of its power, P_ref = REF_SHARE x the rating of its weaker real pole.
* Distribution networks: sources are the transformer outputs and the poles that pick up
  generators (output: rated). In order of resistance-weighted distance d, each pole's machine
  load goes whole to its nearest transformer output, or to its nearest generators while they
  have output left (a pole is never split); a transformer input takes from its nearest
  generators while they have output left, then the rest from its nearest transformer output.
  Each part loses tree_loss(d) = PER_TILE x d (capped); a transformer pays for the losses on the
  power it supplies; a transformer input reports the loss on what reaches it as its upstream
  line loss. Each pole keeps its K_SOURCES nearest sources.
* A wire straight from a transmission pole to a distribution pole costs MIXED x its resistance, and
  so does every wire between transmission poles inside a distribution network.

Not modelled here: merging of idle chains (which does not change flows), machine weighting, Power
Overload's overload checks.
"""
import heapq
import math

import numpy as np

# --- Settings (mod defaults) ---------------------------------------------------------------
PER_TILE = 0.025 / 100      # line loss per tile of resistance-weighted distance
CAP = 0.95                  # cap per wire and per tree route
EFFICIENCY = 0.99           # transformer efficiency
CORE_LOSS = 0.1 / 100       # of the transformer's rating, while switched on
K_SOURCES = 4               # nearest sources each distribution pole keeps
MIXED = 2                   # resistance multiplier, transmission pole straight to distribution pole
FLOOR = 0.1                 # share of the plain per-tile rate a transmission wire loses at any load
REF_SHARE = 0.25            # I^2 R reference: this share of the wire's weaker pole rating

# Power Overload default ratings (W). "compact" is Line loss's compact substation.
RATINGS = {
    "small": 10e6,
    "medium": 60e6,
    "substation": 125e6,
    "compact": 125e6,
    "big": 300e6,
    "huge": 3e9,
}
SUPPLY = {"small": 2.5, "medium": 3.5, "substation": 9, "compact": 3.5, "big": 0, "huge": 0}
HIDDEN = ("out", "in")      # a transformer's hidden output and input poles (resistance 1, no rating)


def resistance(pole_type):
    """Resistance per tile, big pole = 1: r = sqrt(P_big / P_pole); hidden poles 1."""
    if pole_type in HIDDEN:
        return 1.0
    return math.sqrt(RATINGS["big"] / RATINGS[pole_type])


def is_transmission(pole_type):
    return pole_type not in HIDDEN and resistance(pole_type) <= 1 + 1e-9


def is_mixed(ta, tb):
    """A wire straight from a transmission pole to a distribution pole (hidden poles exempt)."""
    if ta in HIDDEN or tb in HIDDEN:
        return False
    return is_transmission(ta) != is_transmission(tb)


def wire_cost(poles, a, b):
    """Resistance-weighted length of the wire a-b (x MIXED for a mixed wire)."""
    (xa, ya, ta), (xb, yb, tb) = poles[a], poles[b]
    c = math.hypot(xa - xb, ya - yb) * (resistance(ta) + resistance(tb)) / 2
    return c * (MIXED if is_mixed(ta, tb) else 1)


def wire_rating(poles, a, b):
    """The weaker of the wire's real poles (hidden poles do not count)."""
    r = [RATINGS[poles[p][2]] for p in (a, b) if poles[p][2] not in HIDDEN]
    return min(r) if r else None


def ratio(loss):
    """Power lost per unit delivered: L / (1 - L)."""
    return loss / (1 - loss)


def from_ratio(r):
    return r / (1 + r)


def tree_loss(d):
    """Loss of the tree route from an entry, resistance-weighted distance d."""
    return min(PER_TILE * d, CAP)


def i2r_share(cost, flow, rating):
    """Share of a transmission wire's power lost on it."""
    if rating is None:
        return min(PER_TILE * cost, CAP)
    return min(PER_TILE * cost * (FLOOR + (1 - FLOOR) * flow / (REF_SHARE * rating)), CAP)


def transformer_draw(output, rating):
    """What a transformer draws to give `output`: output / efficiency + core loss."""
    return output / EFFICIENCY + CORE_LOSS * rating


def key(a, b):
    return (a, b) if a < b else (b, a)


# --- The model ------------------------------------------------------------------------------

def solve(poles, wires, outputs, inputs, machines, generators=None):
    """Run the model on one layout.

    poles: {name: (x, y, type)}; wires: [(a, b)]; outputs: {output pole: power it delivers (W)};
    inputs: {input pole: power its transformer draws (W)}; machines: {pole: machine load (W)}.
    generators: {pole: rated output (W)} of the generators each pole picks up.
    Returns a dict:
      flow, lost:   {wire key: W} on every wire carrying power
      kind:         {wire key: "transmission" | "tree"}
      down:         {output pole: downstream line loss (share of what it sends)}
      burn:         {output pole: W it pays for}
      up:           {input pole: upstream line loss of the last segment}
      shares:       {input pole: {output pole: share of its power}} (distribution)
      region:       {distribution pole: (nearest source, distance)}; generator sources "gen:<pole>"
      supplied:     {source: W it supplies} (distribution)
      fed_by:       {distribution pole: {source: W}} for its machine load
      gen_share:    {input pole: {generator pole: W}} (distribution)
      network:      {pole: "transmission" | "distribution"}
      V:            {Kirchhoff node: potential}
    """
    adj = {p: [] for p in poles}
    for a, b in wires:
        c = wire_cost(poles, a, b)
        adj[a].append((b, c))
        adj[b].append((a, c))
    cls = {}
    for p, (_, _, t) in poles.items():
        cls[p] = "H" if t in HIDDEN else ("T" if is_transmission(t) else "D")
    generators = generators or {}

    # Electric networks (wires never cross a transformer). A network is
    # transmission only if all its poles are transmission poles and it has no
    # generators; otherwise its transmission poles count as distribution.
    comp_of, comps = {}, []
    for p in poles:
        if p in comp_of:
            continue
        stack, members = [p], []
        comp_of[p] = len(comps)
        while stack:
            u = stack.pop()
            members.append(u)
            for v, _ in adj[u]:
                if v not in comp_of:
                    comp_of[v] = len(comps)
                    stack.append(v)
        comps.append(members)
    netkind = {}
    for i, members in enumerate(comps):
        dist_net = any(cls[u] == "D" for u in members) or any(generators.get(u, 0) > 0 for u in members)
        netkind[i] = "distribution" if dist_net else "transmission"
        if dist_net:
            for u in members:
                if cls[u] == "T":
                    cls[u] = "D"
    # In a distribution network every wire touching a transmission pole costs MIXED
    # (those straight to a distribution pole already do)
    for u in poles:
        if netkind[comp_of[u]] == "distribution" and poles[u][2] not in HIDDEN:
            adj[u] = [(v, c * MIXED if is_transmission(poles[u][2]) and is_transmission(poles[v][2])
                       and poles[v][2] not in HIDDEN else c) for v, c in adj[u]]

    # Kirchhoff edges: wires between transmission poles and terminals
    edges = [(a, b, wire_cost(poles, a, b)) for a, b in wires
             if cls[a] != "D" and cls[b] != "D" and "T" in (cls[a], cls[b])]

    # Distribution blocks: groups of distribution poles wired together. Sources:
    # the transformer outputs wired into a block and the poles that pick up
    # generators. Each pole keeps its K nearest sources (multi-source shortest
    # paths, one label per source).
    block_of, blocks = {}, []
    for p in poles:
        if cls[p] == "D" and p not in block_of:
            stack, members = [p], []
            block_of[p] = len(blocks)
            while stack:
                u = stack.pop()
                members.append(u)
                for v, _ in adj[u]:
                    if cls[v] == "D" and v not in block_of:
                        block_of[v] = len(blocks)
                        stack.append(v)
            blocks.append(members)
    dist_info = []          # per block: members, labels, settle order, pins, sources
    for bid, members in enumerate(blocks):
        outs, pins = [], []
        for u in members:
            for v, c in adj[u]:
                if cls[v] == "H":
                    (outs if poles[v][2] == "out" else pins).append((u, v, c))
        heap = [(c, u, v, v, c) for u, v, c in outs]
        heap += [(0.0, g, "gen:" + g, None, 0.0) for g in members if generators.get(g, 0) > 0]
        heapq.heapify(heap)
        labels, settled = {u: {} for u in members}, []
        while heap:
            d, u, src, prev, c = heapq.heappop(heap)
            lab = labels[u]
            if src in lab or len(lab) >= K_SOURCES:
                continue
            lab[src] = (d, prev, c)
            settled.append((u, src))
            for v, cv in adj[u]:
                if cls[v] == "D" and block_of[v] == bid and src not in labels[v] and len(labels[v]) < K_SOURCES:
                    heapq.heappush(heap, (d + cv, v, src, u, cv))
        dist_info.append({"members": members, "labels": labels, "settled": settled, "pins": pins,
                          "outs": sorted({v for _, v, _ in outs}),
                          "gens": [g for g in members if generators.get(g, 0) > 0]})
    dist_pins = {v for b in dist_info for _, v, _ in b["pins"]}
    dist_outs = {o for b in dist_info for o in b["outs"]}

    # Kirchhoff nodes and connected networks
    nodes = set()
    for a, b, _ in edges:
        nodes.update((a, b))
    for p in list(outputs) + list(inputs):
        if p not in dist_outs and p not in dist_pins:
            nodes.add(p)
    nadj = {n: [] for n in nodes}
    for a, b, c in edges:
        nadj[a].append(b)
        nadj[b].append(a)
    nets, seen = [], set()
    for n in sorted(nodes):
        if n in seen:
            continue
        comp, stack = [], [n]
        seen.add(n)
        while stack:
            u = stack.pop()
            comp.append(u)
            for v in nadj[u]:
                if v not in seen:
                    seen.add(v)
                    stack.append(v)
        nets.append(sorted(comp))

    # Injections
    inj_src, inj_load = {}, {}
    flow, lost, kind = {}, {}, {}

    def add_wire(a, b, w, l, k):
        kk = key(a, b)
        flow[kk] = flow.get(kk, 0) + w
        lost[kk] = lost.get(kk, 0) + l
        kind[kk] = k

    for p, w in outputs.items():
        if p not in dist_outs:
            inj_src[p] = inj_src.get(p, 0) + w
    for p, w in inputs.items():
        if p not in dist_pins:
            inj_load[p] = inj_load.get(p, 0) + w
    for p, w in machines.items():
        if w > 0 and cls[p] == "T":
            inj_load[p] = inj_load.get(p, 0) + w

    burn, up, V, shares = {}, {}, {}, {}
    supplied, gen_share, region, fed_by = {}, {}, {}, {}
    up_from_gen = {}
    for b in dist_info:
        labels = b["labels"]
        for p in b["members"]:
            if labels[p]:
                src, (d, _, _) = min(labels[p].items(), key=lambda kv: (kv[1][0], kv[0]))
                region[p] = (src, d)
        cap = {"gen:" + g: generators[g] for g in b["gens"]}     # generators' output left
        # sinks: machine load per pole, transformer inputs (at their pole)
        sinks = [("pole", p, machines.get(p, 0), p, 0.0) for p in b["members"] if machines.get(p, 0) > 0]
        best_pin = {}
        for u, v, c in b["pins"]:
            if inputs.get(v, 0) > 0:
                near = min((dd for dd, _, _ in labels[u].values()), default=math.inf)
                if v not in best_pin or near + c < best_pin[v][0]:
                    best_pin[v] = (near + c, u, c)
        sinks += [("pin", v, inputs[v], u, c) for v, (_, u, c) in best_pin.items()]
        rem = [w for _, _, w, _, _ in sinks]
        taken = [{} for _ in sinks]            # per sink: src -> (W, distance)

        def give(i, src, d):
            """A transformer output takes all of load i; generators all of a pole if they have
            output left, or what they have left of a transformer input."""
            if src.startswith("gen:"):
                if cap[src] <= 0:
                    return False
                l = tree_loss(d)
                t = min(rem[i], cap[src] * (1 - l)) if sinks[i][0] == "pin" else rem[i]
                cap[src] -= t / (1 - l)
            else:
                t = rem[i]
            rem[i] -= t
            taken[i][src] = (taken[i].get(src, (0, d))[0] + t, d)
            return True

        # nearest first; equally near sources alternate from one load to the next
        cand = [(d + c, i, src) for i, (_, _, _, u, c) in enumerate(sinks)
                for src, (d, _, _) in labels[u].items()]
        cand.sort(key=lambda x: (x[0], x[1]))
        k = 0
        while k < len(cand):                   # within a tie (same distance and load): order by name,
            j = k                              # reversed for odd loads
            while j < len(cand) and cand[j][:2] == cand[k][:2]:
                j += 1
            cand[k:j] = sorted(cand[k:j], key=lambda x: x[2], reverse=cand[k][1] % 2 == 1)
            k = j
        for d, i, src in cand:
            if rem[i] > 1e-9:
                give(i, src, d)
        # loads still short (their K nearest are used-up generators): the nearest
        # transformer output or generators with output left, searching outward
        out_at = {}
        for u in b["members"]:
            for v, c in adj[u]:
                if cls[v] == "H" and poles[v][2] == "out":
                    out_at.setdefault(u, []).append((v, c))
        paths = {}
        for i, (_, _, _, u0, c0) in enumerate(sinks):
            if rem[i] <= 1e-9:
                continue
            dist, prev_, heap = {u0: c0}, {}, [(c0, u0)]
            while heap and rem[i] > 1e-9:
                d, u = heapq.heappop(heap)
                if d > dist[u]:
                    continue
                here = [("gen:" + u, d, None)] if generators.get(u, 0) > 0 else []
                here += [(o, d + c, c) for o, c in out_at.get(u, [])]
                for src, dd, cw in here:
                    if rem[i] > 1e-9 and give(i, src, dd):
                        path, x = ([(src, u, cw)] if cw is not None else []), u
                        while x in prev_:
                            path.append((prev_[x][0], x, prev_[x][1])); x = prev_[x][0]
                        paths[(i, src)] = path
                for v, cv in adj[u]:
                    if cls[v] == "D" and block_of[v] == bid and d + cv < dist.get(v, math.inf):
                        dist[v], prev_[v] = d + cv, (u, cv)
                        heapq.heappush(heap, (d + cv, v))
            if rem[i] > 1e-9 and labels[u0]:      # nothing with output left: the nearest source
                src, (d, _, _) = min(labels[u0].items(), key=lambda kv: (kv[1][0], kv[0]))
                taken[i][src] = (taken[i].get(src, (0, d + c0))[0] + rem[i], d + c0)
                rem[i] = 0
        acc = {}
        for i, (sk, ref, w, u, c) in enumerate(sinks):
            tot, lost_, sh, gsh = 0.0, 0.0, {}, {}
            for src, (t, d) in taken[i].items():
                lw = t * ratio(tree_loss(d))
                supplied[src] = supplied.get(src, 0) + t
                if not src.startswith("gen:"):
                    burn[src] = burn.get(src, 0) + lw
                    sh[src] = t
                else:
                    gsh[src[4:]] = t
                tot += t; lost_ += lw
                if (i, src) in paths:          # found by the outward search: its own path
                    for a_, b_, cw in paths[(i, src)]:
                        add_wire(a_, b_, t, t * min(PER_TILE * cw, CAP), "tree")
                else:
                    acc.setdefault(src, {})
                    acc[src][u] = acc[src].get(u, 0) + t
                if sk == "pin":
                    add_wire(ref, u, t, t * min(PER_TILE * c, CAP), "tree")
            if sk == "pole":
                fed_by[ref] = {k: x for k, (x, _) in taken[i].items()}
            if sk == "pin" and tot > 0:
                up[ref] = from_ratio(lost_ / tot)
                shares[ref] = {k: x / tot for k, x in sh.items()}
                gen_share[ref] = gsh
                up_from_gen[ref] = sum(gsh.values()) > tot / 2
        # wires carry each source's power along its shortest paths, farthest first
        for u, src in reversed(b["settled"]):
            a_ = acc.get(src, {}).get(u, 0)
            if a_ > 0:
                d, prev, c = labels[u][src]
                if prev is not None:
                    add_wire(prev, u, a_, a_ * min(PER_TILE * c, CAP), "tree")
                    if prev in labels and src in labels[prev]:
                        acc[src][prev] = acc[src].get(prev, 0) + a_

    for comp in nets:
        supply = sum(inj_src.get(u, 0) for u in comp)
        demand = sum(inj_load.get(u, 0) for u in comp)
        if supply <= 0 or demand <= 0:
            continue
        scale = supply / demand
        idx = {u: i for i, u in enumerate(comp)}
        n = len(comp)
        cedges = [(a, b, c) for a, b, c in edges if a in idx]
        if n > 1:
            G = np.zeros((n, n))
            for a, b, c in cedges:
                i, j, g = idx[a], idx[b], 1 / c
                G[i, i] += g; G[j, j] += g; G[i, j] -= g; G[j, i] -= g
            P = np.array([inj_src.get(u, 0) - inj_load.get(u, 0) * scale for u in comp])
            G[0, :] = 0; G[0, 0] = 1; P[0] = 0           # ground the first node
            x = np.linalg.solve(G, P)
        else:
            x = np.zeros(1)
        for u in comp:
            V[u] = x[idx[u]]
        ins = {u: [] for u in comp}
        for a, b, c in cedges:
            f = (V[a] - V[b]) / c
            src, dst = (a, b) if f >= 0 else (b, a)
            f = abs(f)
            if f <= 0:
                continue
            l = f * i2r_share(c, f, wire_rating(poles, a, b))
            add_wire(a, b, f, l, "transmission")
            ins[dst].append((src, f, l))
        # forward along the flows: loss per unit of power arriving
        rate, arriving = {}, {}
        for u in sorted(comp, key=lambda q: -V[q]):
            arr = inj_src.get(u, 0) + sum(f for _, f, _ in ins[u])
            r = 0.0
            if arr > 0:
                r = sum(f / arr * (rate[s] + l / f) for s, f, l in ins[u])
            rate[u], arriving[u] = r, arr
        # backward: what is consumed pays its node's rate, charged up the flows
        charge = {u: 0.0 for u in comp}
        for u in sorted(comp, key=lambda q: V[q]):
            c = charge[u] + inj_load.get(u, 0) * scale * rate[u]
            arr = arriving[u]
            if c > 0 and arr > 0:
                own = inj_src.get(u, 0)
                if own > 0:
                    burn[u] = burn.get(u, 0) + c * own / arr
                for s, f, _ in ins[u]:
                    charge[s] += c * f / arr
        for u in comp:
            if u in inputs:
                up[u] = from_ratio(rate[u])
    down = {p: from_ratio(burn.get(p, 0) / w) if w > 0 else 0 for p, w in outputs.items()}
    return {"flow": flow, "lost": lost, "kind": kind, "down": down, "burn": burn, "up": up,
            "shares": shares, "region": region, "V": V, "supplied": supplied, "up_from_gen": up_from_gen,
            "fed_by": fed_by,
            "network": {p: netkind[comp_of[p]] for p in poles}, "gen_share": gen_share}


# --- Layout helpers -------------------------------------------------------------------------

def machine_loads(poles, machine_list, weighting, half_size=1.5):
    """Machine load per pole (W), as the mod computes it. machine_list: [(x, y, W)], machines
    of 2 x half_size tiles square (an assembler: 3 x 3). A machine is covered by a pole when it
    overlaps the pole's supply area (SUPPLY tiles each side).
      weighting off: the total of all covered machines spread evenly over the poles with a
                     supply area, wherever the machines are;
      weighting on:  each machine's power split evenly between the poles covering it."""
    suppliers = [p for p, (_, _, t) in poles.items() if SUPPLY.get(t, 0) > 0]
    cover = []
    for x, y, w in machine_list:
        c = [p for p in suppliers
             if abs(poles[p][0] - x) < SUPPLY[poles[p][2]] + half_size
             and abs(poles[p][1] - y) < SUPPLY[poles[p][2]] + half_size]
        cover.append((c, w))
    loads = {p: 0.0 for p in suppliers}
    if not weighting:
        total = sum(w for c, w in cover if c)
        return {p: total / len(suppliers) for p in suppliers} if suppliers else {}
    for c, w in cover:
        for p in c:
            loads[p] += w / len(c)
    return loads


def line(poles, wires, prefix, start, end, n, pole_type, first=None, last=None):
    """n poles evenly spaced from start to end (inclusive), wired in a chain; optionally wired
    to `first` and `last`. Returns the names."""
    (xa, ya), (xb, yb) = start, end
    names = []
    for k in range(n):
        t = k / (n - 1) if n > 1 else 0
        name = f"{prefix}{k}"
        poles[name] = (xa + (xb - xa) * t, ya + (yb - ya) * t, pole_type)
        if names:
            wires.append((names[-1], name))
        names.append(name)
    if first:
        wires.append((first, names[0]))
    if last:
        wires.append((names[-1], last))
    return names


def grid(poles, wires, prefix, x0, y0, nx, ny, spacing, pole_type):
    """A block of poles wired to their right and lower neighbours. Returns {(i, j): name}."""
    names = {}
    for i in range(nx):
        for j in range(ny):
            name = f"{prefix}{i}_{j}"
            poles[name] = (x0 + i * spacing, y0 + j * spacing, pole_type)
            names[i, j] = name
            if i > 0:
                wires.append((names[i - 1, j], name))
            if j > 0:
                wires.append((names[i, j - 1], name))
    return names


def transformer(poles, name, x, y):
    """A transformer: its input pole at x - 0.6, output pole at x + 0.6. Returns (in, out)."""
    poles[name + ".in"] = (x - 0.6, y, "in")
    poles[name + ".out"] = (x + 0.6, y, "out")
    return name + ".in", name + ".out"


# --- Drawing -------------------------------------------------------------------------------

POLE_STYLE = {   # marker size, wire colour, wire width, marker
    "small": (14, "#b4b2a9", 0.6, "v"),
    "medium": (22, "#888780", 0.9, "o"),
    "compact": (30, "#5f5e5a", 1.1, "p"),
    "substation": (40, "#5f5e5a", 1.2, "^"),
    "big": (34, "#3b6fb6", 1.4, "D"),
    "huge": (55, "#2c2c2a", 2.0, "h"),
}


def draw(ax, poles, wires, result=None, value="flow", vmax=None, cmap="viridis", labels="flow",
         title=None, colorbar=True, names=None, min_label=0.05e6):
    """Draw the layout to scale (tiles). With a result, each wire is coloured and sized by
    `value` ("flow" in W, "lost" in W, or "loading": flow / wire rating). labels: "flow",
    "lost", "loading" or None writes that value on the wires carrying power. names: {pole: text}
    drawn next to poles. Transformers (hidden poles) are drawn as green squares."""
    import matplotlib.pyplot as plt
    from matplotlib import cm, colors

    def wire_value(a, b, which):
        if result is None:
            return 0
        k = key(a, b)
        f = result["flow"].get(k, 0)
        if which == "flow":
            return f
        if which == "lost":
            return result["lost"].get(k, 0)
        r = wire_rating(poles, a, b)
        return f / r if r else 0

    vals = [wire_value(a, b, value) for a, b in wires]
    top = vmax or (max(vals) if vals and max(vals) > 0 else 1)
    norm = colors.Normalize(0, top)
    cmap_ = cm.get_cmap(cmap) if hasattr(cm, "get_cmap") else plt.get_cmap(cmap)
    for (a, b), v in zip(wires, vals):
        (xa, ya, ta), (xb, yb, tb) = poles[a], poles[b]
        if result is not None and v > 0:
            ax.plot([xa, xb], [ya, yb], color=cmap_(norm(v)), lw=1 + 6 * min(v / top, 1.2), zorder=1,
                    solid_capstyle="round")
        else:
            t = ta if ta not in HIDDEN and (tb in HIDDEN or resistance(ta) >= resistance(tb)) else tb
            ax.plot([xa, xb], [ya, yb], color="#cccccc" if result is not None else POLE_STYLE.get(t, POLE_STYLE["big"])[1],
                    lw=0.8, zorder=1)
        if result is not None and labels and v > 0:
            lv = wire_value(a, b, labels)
            if labels == "loading":
                text = f"{lv:.0%}"
            elif lv >= min_label:
                text = f"{lv / 1e6:.1f}" if lv >= 1e6 else f"{lv / 1e3:.0f}k"
            else:
                text = None
            if text:
                ax.annotate(text, ((xa + xb) / 2, (ya + yb) / 2), fontsize=6.5, ha="center", va="center",
                            zorder=5, bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.8))
    by_type = {}
    for p, (x, y, t) in poles.items():
        if t not in HIDDEN:
            by_type.setdefault(t, []).append((x, y))
    for t, pts in by_type.items():
        size, _, _, marker = POLE_STYLE[t]
        ax.scatter([p[0] for p in pts], [p[1] for p in pts], s=size, marker=marker,
                   c="#3b6fb6" if is_transmission(t) else "white", edgecolor="k", linewidth=0.5, zorder=3)
    done = set()
    for p, (x, y, t) in poles.items():
        if t in HIDDEN:
            base = p.rsplit(".", 1)[0]
            if base in done:
                continue
            done.add(base)
            ax.scatter([x + (0.6 if t == "in" else -0.6)], [y], s=120, marker="s", c="#1d9e75",
                       edgecolor="k", zorder=4)
            ax.annotate(base, (x, y), textcoords="offset points", xytext=(0, 8), ha="center",
                        fontsize=8, weight="bold", zorder=6)
    for p, text in (names or {}).items():
        ax.annotate(text, poles[p][:2], textcoords="offset points", xytext=(0, -12), ha="center",
                    fontsize=7.5, color="#993c1d", weight="bold", zorder=6)
    ax.set_aspect("equal")
    ax.set_xlabel("tiles")
    ax.invert_yaxis()   # Factorio's y grows downwards
    ax.margins(0.06)
    if title:
        ax.set_title(title, fontsize=10)
    if result is not None and colorbar:
        sm = cm.ScalarMappable(norm=colors.Normalize(0, top / (1 if value == "loading" else 1e6)), cmap=cmap_)
        label = {"flow": "power on the wire (MW)", "lost": "power lost on the wire (MW)",
                 "loading": "share of the wire's rating"}[value]
        plt.colorbar(sm, ax=ax, label=label, shrink=0.75)
