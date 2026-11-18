-- Line losses on distribution networks: nearest source, never splitting a pole.
--
-- A distribution network has a distribution pole or generators (see
-- kirchhoff.lua, which runs this as part of its job). Its poles form blocks.
-- Sources: the transformer outputs wired to a block and the poles that pick up
-- generators (output: rated, solar panels scaled by daylight). Distance is
-- resistance-weighted; a wire between two transmission poles here costs the
-- mixed-wire multiplier, like a wire from a transmission pole to a
-- distribution pole. Each pole keeps its K nearest sources.
--
-- Every refresh, each pole's machine load goes whole to its nearest source:
-- its nearest transformer output, or its nearest generators while they have
-- output left. A transformer input takes from its nearest generators while
-- they have output left, then from its nearest transformer output. Power loses
-- per_tile x distance on the way; a transformer pays for the losses on what it
-- supplies.

local lib = kirchhoff_lib
local push, pop, node, kstate, result, add_wire = lib.push, lib.pop, lib.node, lib.kstate, lib.result, lib.add_wire
local K_SOURCES = lib.K_SOURCES

-- Wire cost on a distribution network: a wire between two transmission poles
-- costs the mixed-wire multiplier too (a wire from a transmission pole to a
-- distribution pole already does), so transmission poles in a factory block
-- are no shortcut
local function dist_cost(demoted, u, v, c)
  if demoted[u] and demoted[v] then return c * (storage.settings.mixed or 1) end
  return c
end

-- Sources of each block: transformer outputs wired to it and poles that pick
-- up generators; each pole keeps its K nearest sources (multi-source shortest
-- paths with one label per source; resumable). Source keys: an output's
-- terminal unit (number), "g<pole unit>" for generators.
function distribution_sources(job, budget)
  local t = job.t
  local cls, terminal, block_of, used = t.cls, t.terminal, t.block_of, 0
  while used < budget do
    local run = t.run
    if not run then
      if t.i > #t.blocks then t.i = 1 return used, "merge_scan" end
      local id = t.i
      t.i = t.i + 1
      local members = t.blocks[id]
      local b = {members = members, labels = {}, settled = {}, pins = {}, outs = {}, out_at = {}, gens = {}}
      local heap = {}
      used = used + #members
      for _, u in ipairs(members) do
        b.labels[u] = {n = 0}
        local nd = node(u)
        local adj = nd and nd.adj or {}
        for x = 1, #adj, 3 do
          local v = adj[x]
          if cls[v] == "H" then
            if terminal[v].out then
              if not b.outs[v] then b.outs[v] = true end
              local list = b.out_at[u]
              if not list then list = {}; b.out_at[u] = list end
              list[#list + 1] = {v, adj[x + 2]}
              push(heap, {adj[x + 2], u, v, v, adj[x + 2]})   -- distance, pole, source, previous, wire cost
            else
              b.pins[#b.pins + 1] = {pole = u, pin = v, c = adj[x + 2]}
            end
          end
        end
        if t.gen_at[u] then
          b.gens[#b.gens + 1] = u
          push(heap, {0, u, "g" .. u, false, 0})
        end
      end
      t.dist[#t.dist + 1] = b
      t.run = {id = id, heap = heap, b = b}
    else
      local heap, id, b = run.heap, run.id, run.b
      local labels, settled = b.labels, b.settled
      while #heap > 0 and used < budget do
        local item = pop(heap)
        local d, u, src = item[1], item[2], item[3]
        local lab = labels[u]
        used = used + 1
        if not lab[src] and lab.n < K_SOURCES then
          lab[src] = {d, item[4], item[5]}
          lab.n = lab.n + 1
          settled[#settled + 1] = {u, src}
          local nd = node(u)
          local adj = nd and nd.adj or {}
          used = used + math.floor(#adj / 3)
          for x = 1, #adj, 3 do
            local v = adj[x]
            local lv = cls[v] == "D" and block_of[v] == id and labels[v]
            if lv and not lv[src] and lv.n < K_SOURCES then
              local c = dist_cost(t.demoted, u, v, adj[x + 2])
              push(heap, {d + c, v, src, u, c})
            end
          end
        end
      end
      if #heap == 0 then t.run = nil end
    end
  end
  return used
end

-- Solar output now, as a share of rated: the surface's daylight (0 at the
-- darkest, 1 at full day) times its solar multiplier
local function solar_factor(surface_index)
  local ok, f = pcall(function()
    local surface = game.surfaces[surface_index]
    local min = surface.min_brightness or 0.15
    local light = math.max(0, math.min(1, (1 - surface.darkness - min) / math.max(1 - min, 1e-6)))
    return light * (surface.solar_power_multiplier or 1)
  end)
  return ok and f or 1
end

-- Assignment, per block (solve stage "assign"). Loads: the machine load on
-- each pole, and each transformer input wired to the block. In order of
-- distance:
--   * a pole goes whole to its nearest transformer output, or to its nearest
--     generators if they have output left (a pole is never split);
--   * a transformer input takes from the nearest generators while they have
--     output left, then the rest from its nearest transformer output.
-- A load whose K nearest sources are all used-up generators searches outward
-- for the nearest transformer output or generators with output left. Each
-- part loses the linear loss of its route; a transformer output pays for the
-- losses on what it supplies; a transformer input gets the loss on what
-- reaches it (upstream line loss) and its feeders' shares. Wires carry each
-- source's power along its shortest paths.
function distribution_assign(job, budget)
  local s, st = job.s, kstate()
  local topo = st.topo
  local b = topo.dist and topo.dist[s.b]
  if not b then return 1, "inject" end
  s.b = s.b + 1
  local transformers, terminal, gen_at = storage.transformers, topo.terminal, topo.gen_at
  local per_tile = storage.settings.per_tile / 100
  local labels, wire_loads = b.labels, s.wire_loads
  local function loss(d) return math.min(per_tile * d, 0.95) end
  local cap = {}                       -- generators' output left
  for _, g in ipairs(b.gens) do
    local ga = gen_at[g]
    cap["g" .. g] = ga.w + (ga.s > 0 and ga.s * solar_factor(ga.surface) or 0)
  end
  local sinks = {}
  for _, u in ipairs(b.members) do
    local w = s.load[u]
    if w and w > 0 then sinks[#sinks + 1] = {pole = u, w = w, c = 0} end
  end
  local best_pin, pin_list = {}, {}
  for _, p in ipairs(b.pins) do
    local info = terminal[p.pin]
    local parts = info and transformers[info.unit]
    local w = parts and parts.p_draw or 0
    if w > 0 then
      local near = math.huge
      for src, l in pairs(labels[p.pole]) do
        if src ~= "n" and l[1] < near then near = l[1] end
      end
      local cur = best_pin[p.pin]
      if not cur then pin_list[#pin_list + 1] = p.pin end
      if not cur or near + p.c < cur.near then
        best_pin[p.pin] = {near = near + p.c, pole = p.pole, c = p.c, w = w, unit = info.unit, pin = p.pin}
      end
    end
  end
  for _, pin in ipairs(pin_list) do sinks[#sinks + 1] = best_pin[pin] end
  local used = #b.members + #sinks
  s.pole_src = s.pole_src or {}
  if #sinks == 0 then
    for _, u in ipairs(b.members) do
      local best, best_d
      for src, l in pairs(labels[u]) do
        if src ~= "n" and (not best_d or l[1] < best_d) then best, best_d = src, l[1] end
      end
      s.pole_src[u] = best
    end
    return used
  end
  local rem, taken = {}, {}
  for i, sk in ipairs(sinks) do rem[i], taken[i] = sk.w, {} end
  -- Give load i what source src can take at distance d: a transformer output
  -- takes all of it; generators take all of a pole if they have output left,
  -- or what they have left of a transformer input
  local function give(i, src, d)
    local amount
    if type(src) == "number" then
      amount = rem[i]
    else
      if (cap[src] or 0) <= 0 then return false end
      local l = loss(d)
      amount = sinks[i].pin and math.min(rem[i], cap[src] * (1 - l)) or rem[i]
      cap[src] = cap[src] - amount / (1 - l)
    end
    rem[i] = rem[i] - amount
    local e = taken[i][src]
    if e then e[1] = e[1] + amount else taken[i][src] = {amount, d} end
    return true
  end
  local cand = {}
  for i, sk in ipairs(sinks) do
    for src, l in pairs(labels[sk.pole]) do
      if src ~= "n" then cand[#cand + 1] = {l[1] + sk.c, i, src} end
    end
  end
  -- nearest first; equally near sources alternate from one load to the next,
  -- so a boundary at equal distance divides evenly
  table.sort(cand, function(x, y)
    if x[1] ~= y[1] then return x[1] < y[1] end
    if x[2] ~= y[2] then return x[2] < y[2] end
    local a, b = tostring(x[3]), tostring(y[3])
    if x[2] % 2 == 0 then return a < b end
    return a > b
  end)
  used = used + #cand * 2
  for _, c in ipairs(cand) do
    if rem[c[2]] > 1e-9 then give(c[2], c[3], c[1]) end
  end
  -- loads still short: nearest transformer output or generators with output
  -- left, searching outward
  local paths = {}
  for i, sk in ipairs(sinks) do
    if rem[i] > 1e-9 then
      local dist, prev, heap = {[sk.pole] = sk.c}, {}, {}
      push(heap, {sk.c, sk.pole})
      while #heap > 0 and rem[i] > 1e-9 do
        local item = pop(heap)
        local d, u = item[1], item[2]
        used = used + 1
        if d <= dist[u] then
          local here = {}
          if gen_at[u] then here[1] = {"g" .. u, d, false} end
          for _, oc in ipairs(b.out_at[u] or {}) do here[#here + 1] = {oc[1], d + oc[2], oc[2]} end
          for _, h in ipairs(here) do
            if rem[i] > 1e-9 and give(i, h[1], h[2]) then
              local path = {}
              if h[3] then path[1] = {h[1], u, h[3]} end
              local x = u
              while prev[x] do
                path[#path + 1] = {prev[x][1], x, prev[x][2]}
                x = prev[x][1]
              end
              paths[i .. "/" .. tostring(h[1])] = path
            end
          end
          local nd = node(u)
          local adj = nd and nd.adj or {}
          for x = 1, #adj, 3 do
            local v = adj[x]
            if labels[v] then
              local c = dist_cost(topo.demoted, u, v, adj[x + 2])
              local dv = d + c
              if dv < (dist[v] or math.huge) then
                dist[v], prev[v] = dv, {u, c}
                push(heap, {dv, v})
              end
            end
          end
        end
      end
      if rem[i] > 1e-9 then      -- nothing with output left: the nearest source
        local best, best_d
        for src, l in pairs(labels[sk.pole]) do
          if src ~= "n" and (not best_d or l[1] < best_d) then best, best_d = src, l[1] end
        end
        if best then
          local e = taken[i][best]
          if e then e[1] = e[1] + rem[i] else taken[i][best] = {rem[i], best_d + sk.c} end
          rem[i] = 0
        end
      end
    end
  end
  -- losses, shares, wire loads
  local acc = {}
  for i, sk in ipairs(sinks) do
    local tot, lost, gen, shares = 0, 0, 0, {}
    local parts_i = {}
    for src, e in pairs(taken[i]) do
      local t, d = e[1], e[2]
      local l = loss(d)
      local lw = t * l / (1 - l)
      if type(src) == "number" then
        local unit = terminal[src].unit
        local res = result(s, unit)
        res.burn = res.burn + lw
        shares[unit] = (shares[unit] or 0) + t
      else
        gen = gen + t
      end
      tot, lost = tot + t, lost + lw
      local path = paths[i .. "/" .. tostring(src)]
      if sk.pin then parts_i[#parts_i + 1] = {src, t, path} end
      if path then
        for _, w in ipairs(path) do add_wire(wire_loads, w[1], w[2], t, t * loss(w[3])) end
      else
        local a = acc[src]
        if not a then a = {}; acc[src] = a end
        a[sk.pole] = (a[sk.pole] or 0) + t
      end
      if sk.pin then add_wire(wire_loads, sk.pin, sk.pole, t, t * loss(sk.c)) end
    end
    if sk.pin and tot > 0 then
      local res = result(s, sk.unit)
      res.up, res.up_from_gen = lost / tot, gen > tot / 2
      for k, f in pairs(shares) do shares[k] = f / tot end
      if gen > 0 then shares.gen = gen / tot end
      res.shares = shares
      -- wires carrying its power (hover highlight), and its generator poles
      local feed, gen_src = {{sk.pole, sk.pin, 1}}, {}
      for _, pt in ipairs(parts_i) do
        local src, t, path = pt[1], pt[2], pt[3]
        local f = t / tot
        if path then
          for _, w in ipairs(path) do feed[#feed + 1] = {w[1], w[2], f} end
        else
          local u = sk.pole
          local l = labels[u] and labels[u][src]
          while l and l[2] do
            feed[#feed + 1] = {l[2], u, f}
            u = l[2]
            l = labels[u] and labels[u][src]
          end
        end
        if type(src) == "string" then gen_src[tonumber(src:sub(2))] = f end
      end
      res.feed, res.gen_src = feed, gen_src
    end
  end
  -- source of every pole (networks view): its load's, else its nearest
  local pole_src = s.pole_src
  for _, u in ipairs(b.members) do
    local best, best_d
    for src, l in pairs(labels[u]) do
      if src ~= "n" and (not best_d or l[1] < best_d) then best, best_d = src, l[1] end
    end
    pole_src[u] = best
  end
  for i, sk in ipairs(sinks) do
    if not sk.pin then
      for src in pairs(taken[i]) do pole_src[sk.pole] = src end
    end
  end
  local settled = b.settled
  for x = #settled, 1, -1 do
    local u, src = settled[x][1], settled[x][2]
    local a = acc[src]
    local w = a and a[u]
    if w and w > 0 then
      local l = labels[u][src]
      local p = l[2]
      if p then
        add_wire(wire_loads, p, u, w, w * loss(l[3]))
        if labels[p] and labels[p][src] then a[p] = (a[p] or 0) + w end
      end
    end
  end
  return used + #settled
end
