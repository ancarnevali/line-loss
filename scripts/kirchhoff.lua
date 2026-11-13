-- Line losses: Kirchhoff on transmission networks (I²R losses); distribution
-- networks in scripts/distribution.lua (nearest source, linear losses), run as
-- stages of the same job.
--
-- Transmission poles are those rated like a big pole or more (resistance of
-- a big pole or less); the rest are distribution poles. A transformer's
-- hidden input and output poles are terminals. An electric network is
-- transmission when all its poles are transmission poles, no pole on it picks
-- up generators and no transformer on it is fed straight by generators;
-- otherwise it is distribution, and its transmission poles count as
-- distribution poles.
--
-- Topology (rebuilt when the wire cache changes or a generator is built or
-- removed):
--   * Generators: the generators each pole picks up (first pole to find one).
--   * Distribution poles form blocks (groups wired to each other). Sources:
--     the transformer outputs wired to a block and the poles that pick up
--     generators. Each pole keeps its K nearest sources by resistance-weighted
--     distance (multi-source shortest paths, one label per source). Wires
--     between transmission poles cost the mixed-wire multiplier there.
--   * Kirchhoff nodes: transmission poles and terminals of transmission
--     networks; edges: the wires between them (conductance 1 / resistance-
--     weighted length). Chains of transmission poles that power nothing (no
--     supply area) with two neighbours are merged.
--
-- Every REFRESH ticks:
--   * Distribution (solve stage "assign"): scripts/distribution.lua.
--   * Transmission: injections are the power each transformer delivers (+),
--     each transformer's draw (-) and machine loads on transmission poles (-);
--     loads are scaled to the supply. G V = I is solved by conjugate gradient
--     (diagonal preconditioner), warm-started. V is a potential, not a
--     voltage: power plays the current, so the flows split over parallel
--     routes inversely to their resistance. Flow on a wire: (V_a - V_b) / R.
--     Loss on a wire: I²R with a floor, a share
--     per_tile x R x (FLOOR + (1 - FLOOR) x |f| / P_ref) of its power, P_ref =
--     REF_SHARE x the wire's rating (the weaker pole). Traced along the flows:
--     forward (decreasing V), each node gets the loss per unit of power
--     reaching it; backward, what is consumed at a node pays that rate,
--     charged up the flows to the sources in proportion. Each transformer
--     input gets its upstream loss (the rate at its node) and its sources'
--     shares (walked back up the flows).
--
-- The work runs as a job, WORK units a tick (a unit: about one pole, wire or
-- node visited), all state in storage; the last topology and results stay in
-- use until a new one is complete.

local REFRESH = 300
local START = 13              -- tick in the period a refresh starts
local FLOOR = 0.1             -- share of the plain per-tile loss a transmission wire has at any load
local REF_SHARE = 0.25        -- I²R reference: this share of the wire's rating
local K_SOURCES = 4           -- nearest sources each distribution pole keeps
local REBUILD_EVERY = 3600    -- also rebuilt on wire changes
local WORK = 2000             -- units per tick
local CG_MAX = 300
local CG_TOL = 1e-6
local NEAREST_ENTRIES = 3     -- edges from a terminal inside a block
local MIN_COST = 0.01

local function kstate()
  storage.kirchhoff = storage.kirchhoff or {V = {}}
  return storage.kirchhoff
end

local function wire_key(a, b)
  if a < b then return a .. ":" .. b end
  return b .. ":" .. a
end

-- Heap of {key, ...}
local function push(h, item)
  local i = #h + 1
  h[i] = item
  while i > 1 do
    local p = math.floor(i / 2)
    if h[p][1] <= item[1] then break end
    h[i], h[p] = h[p], item
    i = p
  end
end
local function pop(h)
  local top, last = h[1], h[#h]
  h[#h] = nil
  local n = #h
  if n > 0 then
    local i = 1
    h[1] = last
    while true do
      local l, r, m = 2 * i, 2 * i + 1, i
      if l <= n and h[l][1] < h[m][1] then m = l end
      if r <= n and h[r][1] < h[m][1] then m = r end
      if m == i then break end
      h[i], h[m] = h[m], h[i]
      i = m
    end
  end
  return top
end

-- Topology stages -------------------------------------------------------------------------
-- job.t holds the topology being built.

local topo_stages = {}

-- Snapshot the poles, terminals
function topo_stages.start(job)
  local t = {units = {}, cls = {}, terminal = {}, edges = {}, block_of = {}, blocks = {},
    dist = {}, gen_at = {}, gen_seen = {}, demoted = {}, rating = {}, i = 1}
  for unit in pairs(storage.wire_graph or {}) do t.units[#t.units + 1] = unit end
  for unit, parts in pairs(storage.transformers) do
    if parts.pole_out and parts.pole_out.valid then t.terminal[parts.pole_out.unit_number] = {unit = unit, out = true} end
    if parts.pole_in and parts.pole_in.valid then t.terminal[parts.pole_in.unit_number] = {unit = unit, out = false} end
  end
  job.t = t
  return math.floor(#t.units / 4) + 1, "classify"
end

local function node(unit) return storage.wire_graph and storage.wire_graph[unit] end

function topo_stages.classify(job, budget)
  local t = job.t
  local units, cls, n = t.units, t.cls, #t.units
  local i, stop = t.i, math.min(#t.units, t.i + budget - 1)
  for x = i, stop do
    local unit = units[x]
    local nd = node(unit)
    if nd then
      if nd.h then
        if t.terminal[unit] then cls[unit] = "H" end
      elseif line_loss_resistance(nd.n) <= 1 + 1e-9 then
        cls[unit] = "T"
      else
        cls[unit] = "D"
      end
    end
  end
  t.i = stop + 1
  if t.i > n then t.i = 1 return stop - i + 1, "gens" end
  return stop - i + 1
end

-- Generators each pole picks up (each generator counted once, for the first
-- pole that finds it): rated output, solar panels apart (scaled by daylight)
function topo_stages.gens(job, budget)
  local t = job.t
  local units, cls, n, used = t.units, t.cls, #t.units, 0
  while t.i <= n and used < budget do
    local unit = units[t.i]
    t.i = t.i + 1
    local nd = node(unit)
    used = used + 1
    if cls[unit] and cls[unit] ~= "H" and nd and (nd.reach or 0) > 0 and nd.e and nd.e.valid then
      used = used + 39         -- an area search: at most about 50 a tick
      local w, sol, surface = 0, 0, nil
      for _, g in pairs(line_loss_search.generators_near(nd.e, nd.reach)) do
        local id = g.unit_number
        if id and not t.gen_seen[id] then
          t.gen_seen[id] = true
          local rated = line_loss_search.rated_output(g)
          if g.type == "solar-panel" then sol = sol + rated else w = w + rated end
          surface = g.surface.index
        end
      end
      if w + sol > 0 then t.gen_at[unit] = {w = w, s = sol, surface = surface} end
    end
  end
  if t.i > n then t.i, t.gen_seen, t.comp_of, t.comps = 1, nil, {}, {} return used, "networks" end
  return used
end

-- Electric networks (wires never cross a transformer: its input and output
-- poles are not wired together). A network is transmission when all its poles
-- are transmission poles and no transformer on it is fed straight by
-- generators; otherwise it is distribution, and its transmission poles are
-- treated as distribution poles (trees, linear loss).
function topo_stages.networks(job, budget)
  local t = job.t
  local units, cls, comp_of, used = t.units, t.cls, t.comp_of, 0
  local transformers, terminal = storage.transformers, t.terminal
  while used < budget do
    local fill = t.fill
    if fill then
      local stack, c = fill.stack, t.comps[fill.id]
      while #stack > 0 and used < budget do
        local u = stack[#stack]
        stack[#stack] = nil
        local cu = cls[u]
        if cu == "D" or t.gen_at[u] then c.distribution = true end
        if cu == "H" and not terminal[u].out then
          local parts = transformers[terminal[u].unit]
          if parts and parts.gen_fed then c.distribution = true end
        end
        c.members[#c.members + 1] = u
        local nd = node(u)
        local adj = nd and nd.adj or {}
        used = used + math.floor(#adj / 3) + 1
        -- (wires to Power Overload's other surface lead to unclassified
        -- hidden poles and are skipped)
        for x = 1, #adj, 3 do
          local v = adj[x]
          if cls[v] and not comp_of[v] then
            comp_of[v] = fill.id
            stack[#stack + 1] = v
          end
        end
      end
      if #stack == 0 then t.fill = nil end
    else
      if t.i > #units then
        -- distribution networks: their transmission poles become distribution
        for _, c in ipairs(t.comps) do
          if c.distribution then
            local n = 0
            for _, u in ipairs(c.members) do
              if cls[u] == "T" then cls[u], t.demoted[u], n = "D", true, n + 1 end
            end
            c.transmission = n  -- transmission poles found in it
          end
          c.members = nil
        end
        t.i = 1
        return used + #t.comps, "direct"
      end
      local unit = units[t.i]
      t.i = t.i + 1
      used = used + 1
      if cls[unit] and not comp_of[unit] then
        local id = #t.comps + 1
        t.comps[id] = {members = {}, distribution = false}
        comp_of[unit] = id
        t.fill = {id = id, stack = {unit}}
      end
    end
  end
  return used
end

-- Wires between transmission poles, and between them and terminals
function topo_stages.direct(job, budget)
  local t = job.t
  local units, cls, n, used = t.units, t.cls, #t.units, 0
  while t.i <= n and used < budget do
    local unit = units[t.i]
    t.i = t.i + 1
    local c = cls[unit]
    if c == "T" or c == "H" then
      local adj = node(unit).adj
      used = used + math.floor(#adj / 3) + 1
      for x = 1, #adj, 3 do
        local other = adj[x]
        local oc = cls[other]
        if unit < other and (oc == "T" or oc == "H") and (c == "T" or oc == "T") then
          t.edges[#t.edges + 1] = {a = unit, b = other, cost = math.max(adj[x + 2], MIN_COST),
            wires = {{unit, other, adj[x + 2]}}}
        end
      end
    else
      used = used + 1
    end
  end
  if t.i > n then t.i = 1 return used, "blocks" end
  return used
end

-- Distribution blocks (resumable flood fill)
function topo_stages.blocks(job, budget)
  local t = job.t
  local units, cls, block_of, n, used = t.units, t.cls, t.block_of, #t.units, 0
  while used < budget do
    local fill = t.fill
    if fill then
      local stack, members, id = fill.stack, t.blocks[fill.id], fill.id
      while #stack > 0 and used < budget do
        local u = stack[#stack]
        stack[#stack] = nil
        members[#members + 1] = u
        local nd = node(u)
        local adj = nd and nd.adj or {}
        used = used + math.floor(#adj / 3) + 1
        for x = 1, #adj, 3 do
          local v = adj[x]
          if cls[v] == "D" and not block_of[v] then
            block_of[v] = id
            stack[#stack + 1] = v
          end
        end
      end
      if #stack == 0 then t.fill = nil end
    else
      if t.i > n then t.i = 1 return used, "sources" end
      local unit = units[t.i]
      t.i = t.i + 1
      used = used + 1
      if cls[unit] == "D" and not block_of[unit] then
        local id = #t.blocks + 1
        t.blocks[id] = {}
        block_of[unit] = id
        t.fill = {id = id, stack = {unit}}
      end
    end
  end
  return used
end

-- Sources of each block and each pole's nearest ones: scripts/distribution.lua
function topo_stages.sources(job, budget) return distribution_sources(job, budget) end

-- Merge idle chains: transmission poles that power nothing (no supply area)
-- with exactly two neighbours
function topo_stages.merge_scan(job, budget)
  local t = job.t
  if not t.incident then
    t.incident, t.i = {}, 1
  end
  local edges, incident, used = t.edges, t.incident, 0
  while t.i <= #edges and used < budget do
    local e = edges[t.i]
    local list = incident[e.a]
    if not list then list = {}; incident[e.a] = list end
    list[#list + 1] = t.i
    list = incident[e.b]
    if not list then list = {}; incident[e.b] = list end
    list[#list + 1] = t.i
    t.i = t.i + 1
    used = used + 1
  end
  if t.i > #edges then
    t.candidates, t.removed, t.i = {}, {}, 1
    for unit, list in pairs(incident) do
      if #list == 2 and t.cls[unit] == "T" then t.candidates[#t.candidates + 1] = unit end
    end
    return used + #edges, "merge"
  end
  return used
end

function topo_stages.merge(job, budget)
  local t = job.t
  local edges, incident, removed, used = t.edges, t.incident, t.removed, 0
  while t.i <= #t.candidates and used < budget do
    local unit = t.candidates[t.i]
    t.i = t.i + 1
    used = used + 2
    local nd = node(unit)
    local inc = incident[unit]
    if nd and (nd.reach or 0) <= 0 and inc and #inc == 2 then
      local i1, i2 = inc[1], inc[2]
      local e1, e2 = edges[i1], edges[i2]
      if i1 ~= i2 and not removed[i1] and not removed[i2] then
        local a = e1.a == unit and e1.b or e1.a
        local b = e2.a == unit and e2.b or e2.a
        if a ~= b then
          local wires = {}
          for _, w in ipairs(e1.wires) do wires[#wires + 1] = w end
          for _, w in ipairs(e2.wires) do wires[#wires + 1] = w end
          removed[i1], removed[i2] = true, true
          edges[#edges + 1] = {a = a, b = b, cost = e1.cost + e2.cost, wires = wires}
          local ni = #edges
          for _, end_unit in ipairs({a, b}) do
            local list = incident[end_unit]
            for k = #list, 1, -1 do
              if list[k] == i1 or list[k] == i2 then table.remove(list, k) end
            end
            list[#list + 1] = ni
          end
          incident[unit] = nil
          used = used + #wires
        end
      end
    end
  end
  if t.i > #t.candidates then
    t.incident, t.candidates, t.kept, t.i = nil, nil, {}, 1
    return used, "ratings"
  end
  return used
end

-- I²R reference per wire: REF_SHARE x its rating (false: no rating, plain loss)
local function pole_rating_of(t, unit)
  local r = t.rating[unit]
  if r == nil then
    r = false
    local nd = node(unit)
    local e = nd and nd.e
    if e and e.valid and not nd.h then r = line_loss_pole_rating(e) or false end
    t.rating[unit] = r
  end
  return r
end

-- Kept edges, their wires' ratings and keys, adjacency
function topo_stages.ratings(job, budget)
  local t = job.t
  local edges, kept, used = t.edges, t.kept, 0
  t.adjacency = t.adjacency or {}
  local adjacency = t.adjacency
  while t.i <= #edges and used < budget do
    local e = edges[t.i]
    t.i = t.i + 1
    used = used + 1
    if not t.removed[t.i - 1] then
      kept[#kept + 1] = e
      local k = #kept
      for _, u in ipairs({e.a, e.b}) do
        local list = adjacency[u]
        if not list then list = {}; adjacency[u] = list end
        list[#list + 1] = k
      end
      for _, w in ipairs(e.wires) do
        local ra, rb = pole_rating_of(t, w[1]), pole_rating_of(t, w[2])
        local rating = (ra and rb) and math.min(ra, rb) or ra or rb
        w[4] = rating and rating * REF_SHARE or false
        w[5] = wire_key(w[1], w[2])
        used = used + 4
      end
    end
  end
  if t.i > #edges then
    t.edges, t.removed, t.rating = nil, nil, nil
    t.starts, t.nets, t.net_of, t.i = {}, {}, {}, 1
    for unit in pairs(adjacency) do t.starts[#t.starts + 1] = unit end
    return used + #t.starts, "nets"
  end
  return used
end

-- Connected networks (resumable flood fill), then each one's solver arrays
function topo_stages.nets(job, budget)
  local t = job.t
  local adjacency, kept, net_of, used = t.adjacency, t.kept, t.net_of, 0
  while used < budget do
    local fill = t.fill
    if fill then
      local stack, list = fill.stack, fill.list
      while #stack > 0 and used < budget do
        local u = stack[#stack]
        stack[#stack] = nil
        list[#list + 1] = u
        local adj = adjacency[u]
        used = used + #adj + 1
        for _, i in ipairs(adj) do
          local e = kept[i]
          local v = e.a == u and e.b or e.a
          if not net_of[v] then
            net_of[v] = fill.id
            stack[#stack + 1] = v
          end
        end
      end
      if #stack == 0 then
        t.nets[fill.id] = {nodes = list}
        t.fill = nil
      end
    else
      if t.i > #t.starts then
        t.starts, t.i, t.k = nil, 1, nil
        return used, "net_arrays"
      end
      local start = t.starts[t.i]
      t.i = t.i + 1
      used = used + 1
      if not net_of[start] then
        local id = #t.nets + 1
        net_of[start] = id
        t.fill = {id = id, stack = {start}, list = {}}
      end
    end
  end
  return used
end

function topo_stages.net_arrays(job, budget)
  local t = job.t
  local used = 0
  while used < budget do
    local net = t.nets[t.i]
    if not net then return used, "install" end
    if not t.k then
      net.idx, net.edges, net.ea, net.eb, net.eg, net.diag = {}, {}, {}, {}, {}, {}
      for k, u in ipairs(net.nodes) do net.idx[u], net.diag[k] = k, 0 end
      t.k = 1
      used = used + #net.nodes
    end
    local nodes, idx, diag = net.nodes, net.idx, net.diag
    while t.k <= #nodes and used < budget do
      local u = nodes[t.k]
      t.k = t.k + 1
      local adj = t.adjacency[u]
      used = used + #adj + 1
      for _, i in ipairs(adj) do
        local e = t.kept[i]
        if e.a == u then
          local k = #net.edges + 1
          local a, b, g = idx[e.a], idx[e.b], 1 / e.cost
          net.edges[k], net.ea[k], net.eb[k], net.eg[k] = e, a, b, g
          diag[a], diag[b] = diag[a] + g, diag[b] + g
        end
      end
    end
    if t.k > #nodes then
      for k = 1, #nodes do diag[k] = diag[k] > 0 and 1 / diag[k] or 0 end
      net.idx = nil
      t.i, t.k = t.i + 1, nil
    end
  end
  return used
end

function topo_stages.install(job)
  local t = job.t
  local topo = {nets = t.nets, net_of = t.net_of, dist = t.dist, gen_at = t.gen_at, demoted = t.demoted,
    terminal = t.terminal, cls = t.cls, comp_of = t.comp_of, comps = t.comps}
  local st = kstate()
  st.topo, st.rev, st.built = topo, job.rev, job.start
  job.t = nil
  return 1, "loads"
end

-- Solve stages ----------------------------------------------------------------------------
-- job.s holds the refresh in progress.

local solve_stages = {}

function solve_stages.loads(job, budget)
  local s = job.s
  if not s then
    s = {poles = {}, i = 1, load = {}, per_owner = {}, wire_loads = {}, results = {}}
    for unit in pairs(storage.pole_dist or {}) do s.poles[#s.poles + 1] = unit end
    job.s = s
  end
  local pole_dist, used = storage.pole_dist or {}, 0
  while s.i <= #s.poles and used < budget do
    local unit = s.poles[s.i]
    s.i = s.i + 1
    local entry = pole_dist[unit]
    if entry then
      local w = pole_machine_load(entry, s.per_owner, job.start)
      if w > 0 then s.load[unit] = w end
    end
    used = used + 2
  end
  if s.i > #s.poles then s.poles, s.per_owner, s.b = nil, nil, 1 return used, "assign" end
  return used
end

local function result(s, unit)
  local r = s.results[unit]
  if not r then r = {burn = 0}; s.results[unit] = r end
  return r
end

local function add_wire(wire_loads, a, b, w, lost, key)
  if w <= 0 then return end
  key = key or wire_key(a, b)
  local e = wire_loads[key]
  if e then
    e.w, e.lost = e.w + w, e.lost + lost
  else
    wire_loads[key] = {a = a, b = b, w = w, lost = lost}
  end
end


-- Distribution blocks: scripts/distribution.lua
function solve_stages.assign(job, budget) return distribution_assign(job, budget) end

function solve_stages.inject(job)
  local s, topo = job.s, kstate().topo
  local transformers, load = storage.transformers, s.load
  local inj_src, inj_load, src_of = {}, {}, {}
  for unit, info in pairs(topo.terminal) do
    local parts = topo.net_of[unit] and transformers[info.unit]
    if parts then
      if info.out then
        inj_src[unit] = (inj_src[unit] or 0) + (parts.p_deliv or 0)
        src_of[unit] = info.unit
      else
        inj_load[unit] = (inj_load[unit] or 0) + (parts.p_draw or 0)
      end
    end
  end
  for unit, c in pairs(topo.cls) do
    if c == "T" and topo.net_of[unit] and load[unit] then
      inj_load[unit] = (inj_load[unit] or 0) + load[unit]
    end
  end
  s.inj_src, s.inj_load, s.src_of, s.load = inj_src, inj_load, src_of, nil
  s.net = 0
  return 10, "next_net"
end

function solve_stages.next_net(job)
  local s, topo = job.s, kstate().topo
  while true do
    s.net = s.net + 1
    local net = topo.nets[s.net]
    if not net then return 1, "hand" end
    local supply, demand = 0, 0
    for _, u in ipairs(net.nodes) do
      supply = supply + (s.inj_src[u] or 0)
      demand = demand + (s.inj_load[u] or 0)
    end
    if supply > 0 and demand > 0 then
      s.scale = supply / demand
      if #net.nodes >= 2 then return #net.nodes, "cg_init" end
      s.k, s.in_edges, s.out_edges = 1, {}, {}
      return 1, "flows"
    end
  end
end

local function apply(net, v, out)
  local n, ea, eb, eg = #net.nodes, net.ea, net.eb, net.eg
  for i = 1, n do out[i] = 0 end
  for k = 1, #ea do
    local i, j = ea[k], eb[k]
    local d = eg[k] * (v[i] - v[j])
    out[i] = out[i] + d
    out[j] = out[j] - d
  end
end

-- PCG on the grounded Laplacian (first node at 0)
function solve_stages.cg_init(job)
  local s, st = job.s, kstate()
  local net = st.topo.nets[s.net]
  local nodes, diag, V = net.nodes, net.diag, st.V
  local n = #nodes
  local x, b, Ax, r, z, p = {}, {}, {}, {}, {}, {}
  for i = 1, n do
    local u = nodes[i]
    x[i] = V[u] or 0
    b[i] = (s.inj_src[u] or 0) - (s.inj_load[u] or 0) * s.scale
  end
  local x1 = x[1]
  for i = 1, n do x[i] = x[i] - x1 end
  apply(net, x, Ax)
  local rz, rr, bb = 0, 0, 0
  r[1], z[1], p[1] = 0, 0, 0
  for i = 2, n do
    local ri = b[i] - Ax[i]
    r[i], z[i] = ri, diag[i] * ri
    p[i] = z[i]
    rz, rr, bb = rz + ri * z[i], rr + ri * ri, bb + b[i] * b[i]
  end
  s.cg = {x = x, r = r, z = z, p = p, rz = rz, rr = rr, tol = CG_TOL * CG_TOL * bb, it = 0}
  return #net.ea + n, "cg"
end

function solve_stages.cg(job, budget)
  local s, st = job.s, kstate()
  local net = st.topo.nets[s.net]
  local cg, n, diag = s.cg, #net.nodes, net.diag
  local x, r, z, p = cg.x, cg.r, cg.z, cg.p
  local cost = #net.ea + 2 * n
  local used, Ap = 0, {}
  while cg.rr > cg.tol and cg.it < CG_MAX and used < budget do
    cg.it = cg.it + 1
    used = used + cost
    apply(net, p, Ap)
    local pAp = 0
    for i = 2, n do pAp = pAp + p[i] * Ap[i] end
    if pAp <= 0 then cg.it = CG_MAX break end
    local alpha = cg.rz / pAp
    local rz_new, rr = 0, 0
    for i = 2, n do
      x[i] = x[i] + alpha * p[i]
      local ri = r[i] - alpha * Ap[i]
      r[i] = ri
      local zi = diag[i] * ri
      z[i] = zi
      rz_new, rr = rz_new + ri * zi, rr + ri * ri
    end
    local beta = rz_new / cg.rz
    for i = 2, n do p[i] = z[i] + beta * p[i] end
    cg.rz, cg.rr = rz_new, rr
  end
  if cg.rr <= cg.tol or cg.it >= CG_MAX then
    local V = st.V
    for i, u in ipairs(net.nodes) do V[u] = x[i] end
    st.iterations = cg.it
    s.cg = nil
    s.k, s.in_edges, s.out_edges = 1, {}, {}
    return used, "flows"
  end
  return used
end

-- Flows and wire losses
function solve_stages.flows(job, budget)
  local s, st = job.s, kstate()
  local net = st.topo.nets[s.net]
  local V, edges, in_edges, wire_loads = st.V, net.edges, s.in_edges, s.wire_loads
  local per_tile = storage.settings.per_tile / 100
  local used = 0
  while s.k <= #edges and used < budget do
    local e = edges[s.k]
    s.k = s.k + 1
    local f = ((V[e.a] or 0) - (V[e.b] or 0)) / e.cost
    local from, to = e.a, e.b
    if f < 0 then from, to, f = e.b, e.a, -f end
    used = used + 3 * #e.wires
    if f > 0 then
      local lost = 0
      for _, w in ipairs(e.wires) do
        local cost, wl = w[3], 0
        if cost > 0 then
          local ref = w[4]
          wl = f * math.min(ref and per_tile * cost * (FLOOR + (1 - FLOOR) * f / ref) or per_tile * cost, 0.95)
        end
        add_wire(wire_loads, w[1], w[2], f, wl, w[5])
        lost = lost + wl
      end
      local list = in_edges[to]
      if not list then list = {}; in_edges[to] = list end
      list[#list + 1] = {from, f, lost}
      list = s.out_edges[from]
      if not list then list = {}; s.out_edges[from] = list end
      list[#list + 1] = to
    end
  end
  if s.k > #edges then return used, "order" end
  return used
end

-- Nodes in flow order (flows run from higher to lower V: no cycles), by
-- repeatedly taking a node all of whose inflows are placed
function solve_stages.order(job, budget)
  local s, st = job.s, kstate()
  local net = st.topo.nets[s.net]
  if not s.order then
    s.order, s.indeg, s.ready = {}, {}, {}
    for _, u in ipairs(net.nodes) do
      local ins = s.in_edges[u]
      local d = ins and #ins or 0
      s.indeg[u] = d
      if d == 0 then s.ready[#s.ready + 1] = u end
    end
    return #net.nodes
  end
  local order, indeg, ready, used = s.order, s.indeg, s.ready, 0
  while #ready > 0 and used < budget do
    local u = ready[#ready]
    ready[#ready] = nil
    order[#order + 1] = u
    local outs = s.out_edges[u]
    used = used + 1 + (outs and #outs or 0)
    if outs then
      for k = 1, #outs do
        local v = outs[k]
        indeg[v] = indeg[v] - 1
        if indeg[v] == 0 then ready[#ready + 1] = v end
      end
    end
  end
  if #ready == 0 then
    s.pos = {}
    for k, u in ipairs(order) do s.pos[u] = k end
    s.indeg, s.ready, s.out_edges = nil, nil, nil
    s.k, s.rate, s.genfrac, s.arriving = 1, {}, {}, {}
    return used, "forward"
  end
  return used
end


-- Forward (decreasing V): loss per unit of power arriving, and the share of
-- that power coming from generators
function solve_stages.forward(job, budget)
  local s, topo = job.s, kstate().topo
  local order, rate, genfrac, arriving, in_edges = s.order, s.rate, s.genfrac, s.arriving, s.in_edges
  local used = 0
  while s.k <= #order and used < budget do
    local u = order[s.k]
    s.k = s.k + 1
    local own = s.inj_src[u] or 0
    local arr = own
    local ins = in_edges[u]
    if ins then for k = 1, #ins do arr = arr + ins[k][2] end end
    local r, g = 0, 0
    if arr > 0 then
      r = 0
      if own > 0 and s.src_of[u] == "gen" then g = own / arr end
      if ins then
        for k = 1, #ins do
          local item = ins[k]
          local w = item[2] / arr
          r = r + w * ((rate[item[1]] or 0) + item[3] / item[2])
          g = g + w * (genfrac[item[1]] or 0)
        end
      end
    end
    rate[u], genfrac[u], arriving[u] = r, g, arr
    used = used + 1 + (ins and #ins or 0)
    local info = topo.terminal[u]
    if info and not info.out then
      local res = result(s, info.unit)
      res.up, res.up_from_gen = r, g > 0.5
    end
  end
  if s.k > #order then s.k, s.charge = #order, {} return used, "backward" end
  return used
end

-- Backward (increasing V): what is consumed at a node pays its rate; the
-- charge goes up the flows to the sources, in proportion
function solve_stages.backward(job, budget)
  local s = job.s
  local order, rate, arriving, in_edges, charge = s.order, s.rate, s.arriving, s.in_edges, s.charge
  local scale, used = s.scale, 0
  while s.k >= 1 and used < budget do
    local u = order[s.k]
    s.k = s.k - 1
    local c = (charge[u] or 0) + (s.inj_load[u] or 0) * scale * rate[u]
    local arr = arriving[u]
    local ins = in_edges[u]
    used = used + 1 + (ins and #ins or 0)
    if c > 0 and arr > 0 then
      local own = s.inj_src[u] or 0
      local key = s.src_of[u]
      if own > 0 and key and key ~= "gen" then
        local res = result(s, key)
        res.burn = res.burn + c * own / arr
      end
      if ins then
        for k = 1, #ins do
          local item = ins[k]
          charge[item[1]] = (charge[item[1]] or 0) + c * item[2] / arr
        end
      end
    end
  end
  if s.k < 1 then
    s.charge = nil
    -- inputs to trace: those on this network
    local topo, list = kstate().topo, {}
    for _, u in ipairs(topo.nets[s.net].nodes) do
      local info = topo.terminal[u]
      if info and not info.out then list[#list + 1] = {unit = info.unit, node = u, ratio = 0} end
    end
    s.share_list, s.si = list, 1
    return used, "shares"
  end
  return used
end

-- Where each transformer input's power comes from: its share walked back up
-- the flows; upstream loss on trees: the tree's own loss on top of the
-- node's rate
function solve_stages.shares(job, budget)
  local s = job.s
  local order, pos, arriving, in_edges = s.order, s.pos, s.arriving, s.in_edges
  local used = 0
  while used < budget do
    local item = s.share_list[s.si]
    if not item then
      s.order, s.pos, s.rate, s.genfrac, s.arriving, s.in_edges, s.share_list = nil, nil, nil, nil, nil, nil, nil
      return used, "next_net"
    end
    if not item.charge then
      item.charge, item.shares, item.p, item.live = {[item.node] = 1}, {}, pos[item.node], 1
      item.feed = {}                   -- wires carrying its power: {from, to, share of its power}
      local res = result(s, item.unit)
      local r = s.rate[item.node] or 0
      res.up = item.ratio + r * (1 + item.ratio)
      res.up_from_gen = (s.genfrac[item.node] or 0) > 0.5
    end
    local charge, shares = item.charge, item.shares
    while item.live > 0 and item.p >= 1 and used < budget do
      local u = order[item.p]
      item.p = item.p - 1
      used = used + 1
      local c = charge[u]
      if c then
        charge[u] = nil
        item.live = item.live - 1
        local arr = arriving[u]
        if arr > 0 then
          local own = s.inj_src[u] or 0
          if own > 0 then
            local key = s.src_of[u] or "gen"
            shares[key] = (shares[key] or 0) + c * own / arr
          end
          local ins = in_edges[u]
          if ins then
            used = used + #ins
            for k = 1, #ins do
              local from = ins[k][1]
              if not charge[from] then
                charge[from] = 0
                item.live = item.live + 1
              end
              charge[from] = charge[from] + c * ins[k][2] / arr
              item.feed[#item.feed + 1] = {from, u, c * ins[k][2] / arr}
            end
          end
        end
      end
    end
    if item.live <= 0 or item.p < 1 then
      local res = result(s, item.unit)
      res.shares, res.feed = shares, item.feed
      s.si = s.si + 1
    end
  end
  return used
end


-- Hand over: transformers' downstream line loss, and upstream for those fed
-- through transmission
function solve_stages.hand(job)
  local s, st = job.s, kstate()
  local tick = job.now
  for unit, parts in pairs(storage.transformers) do
    local res = s.results[unit]
    local delivered = parts.p_deliv or 0
    if res and res.burn > 0 and delivered > 0 then
      local ratio = res.burn / delivered
      parts.kirch_line_loss = ratio / (1 + ratio)
    else
      parts.kirch_line_loss = res and 0 or nil
    end
    parts.kirch_up_loss, parts.kirch_gen_loss = nil, nil
    parts.kirch_shares = res and res.shares or nil
    parts.kirch_feed = res and res.feed or nil         -- hover highlight
    parts.kirch_gen_src = res and res.gen_src or nil
    if res and res.up then
      local l = res.up / (1 + res.up)
      if res.up_from_gen then parts.kirch_gen_loss = l else parts.kirch_up_loss = l end
    end
    parts.kirch_tick = tick
  end
  st.wire_loads, st.tick = s.wire_loads, tick
  st.pole_src = s.pole_src or {}
  job.s = nil
  return 10, nil
end

-- Job -------------------------------------------------------------------------------------

---@param tick GameTick
function kirchhoff_update(tick)
  local settings_ = storage.settings
  if not settings_.enabled then
    if storage.kirchhoff then storage.kirchhoff = nil end
    return
  end
  local st = kstate()
  local job = st.job
  if not job then
    if tick % REFRESH ~= START then return end
    local stale = not st.topo or st.rev ~= storage.wire_graph_rev or tick - (st.built or 0) >= REBUILD_EVERY
    job = {start = tick, rev = storage.wire_graph_rev, stage = stale and "start" or "loads"}
    st.job = job
  end
  job.now = tick
  local budget = WORK
  while budget > 0 do
    local stage = job.stage
    local used, nxt = (topo_stages[stage] or solve_stages[stage])(job, budget)
    budget = budget - math.max(used or 1, 1)
    if stage == "hand" then
      st.job = nil
      return
    end
    if nxt then job.stage = nxt end
  end
end

-- Fresh Kirchhoff values for a transformer, or nil
function kirchhoff_values(parts)
  if not storage.settings.enabled then return nil end
  local t = parts.kirch_tick
  if not t or game.tick - t > 2 * REFRESH + 60 then return nil end
  return parts
end

-- Power on every wire from the last solve (line loading views, overload)
function kirchhoff_wire_loads()
  local st = storage.kirchhoff
  if not st or not st.wire_loads or game.tick - (st.tick or 0) > 2 * REFRESH + 60 then return nil end
  return st.wire_loads
end

-- Whether the electric network of a pole is solved as transmission
-- (Kirchhoff, I²R) or distribution (trees, linear loss); nil while unknown
---@param unit integer  pole unit number
---@return "transmission"|"distribution"|nil
function kirchhoff_network_kind(unit)
  local st = storage.kirchhoff
  local topo = st and st.topo
  local id = topo and topo.comp_of and topo.comp_of[unit]
  local c = id and topo.comps[id]
  if not c then return nil end
  return c.distribution and "distribution" or "transmission"
end

-- Tooltip of a network type label: kind, machine weighting, transmission poles found
---@param kind string?
---@param unit uint?
function network_kind_tooltip(kind, unit)
  local key = kind or "unknown"
  if kind == "distribution" and storage.settings and storage.settings.machine_weighting then
    key = "distribution-weighted"
  end
  return {"line-loss-network." .. key .. "-tooltip", unit and kirchhoff_network_transmission_count(unit) or 0}
end

-- Transmission poles found in the network of a pole (0 for transmission networks)
---@param unit uint
function kirchhoff_network_transmission_count(unit)
  local st = storage.kirchhoff
  local topo = st and st.topo
  local id = topo and topo.comp_of and topo.comp_of[unit]
  local c = id and topo.comps[id]
  return c and c.transmission or 0
end

-- The source feeding a distribution pole (networks view): its transformer's
-- unit, or "gen" for generators; nil off distribution networks
function kirchhoff_pole_source(unit)
  local st = storage.kirchhoff
  local src = st and st.pole_src and st.pole_src[unit]
  if src == nil then return nil end
  if type(src) == "string" then return "gen" end
  local info = st.topo and st.topo.terminal[src]
  return info and info.unit or nil
end

-- Helpers shared with scripts/distribution.lua
kirchhoff_lib = {push = push, pop = pop, node = node, kstate = kstate, result = result, add_wire = add_wire,
  K_SOURCES = K_SOURCES}
