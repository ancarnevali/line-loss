-- Distance-based line losses (distance only: the loss percentage does not
-- grow with power).
--
-- Each transformer gets an electrical distance D: the load-weighted
-- shortest-path distance, along copper wires, from its output pole to the
-- consumers of its output network. Each wire's length is weighted by a
-- resistance factor derived from the poles' maximum consumption, so long runs
-- of small poles cost much more than big or huge pole trunks. The
-- transformer's line loss is the same weighted average taken over each
-- route's own loss, loss_per_tile * d capped at LINE_LOSS_MAX per route, and
-- is burned by its hidden "Line loss" consumer on the output network
-- (transformers.lua).
--
-- Consumers (proportional sharing: every source on a network sees the same
-- consumers with the same weights, only its own distances differ):
--   * downstream transformers, found by the search at their hidden input
--     pole, weighted by the power they draw (including their inefficiency);
--   * everything else (machines) = network consumption without transformers
--     and loss consumers, spread evenly over the network's real poles,
--     because the game does not say which pole powers which machine.
--   D = (sum_k P_k * d_k + P_rest * mean_pole_d) / (sum_k P_k + P_rest)
-- Because each transformer applies its own D to the energy it actually
-- moves, the network's total loss is automatically power-weighted across
-- its sources.
--
-- UPS: D is cached on the transformer. Searches run one transformer at a
-- time, settling at most POLES_PER_TICK poles per tick, and only when its
-- network changed (see Scheduling); otherwise a slow safety round settles
-- SAFETY_POLES_PER_TICK poles per tick. Cost per tick is bounded regardless
-- of base size.

local POLES_PER_TICK = 100        -- searches after a change
local SAFETY_POLES_PER_TICK = 10  -- slow round over everything
local LINE_LOSS_MAX = 0.95  -- the line keeps at least 5% of the power
local HIDDEN_PREFIX = "po-hidden-"
local HIDDEN_INPUT_POLE = "po-hidden-electric-pole-in"

---@param entity LuaEntity
local function is_hidden(entity)
  return string.sub(entity.name, 1, #HIDDEN_PREFIX) == HIDDEN_PREFIX
end

-- Resistance per tile, relative to the big electric pole (= 1), from Power
-- Overload's pole ratings (ratings.lua). Unrated poles count as 1. Derived
-- only from startup settings and the active mods, so every client computes
-- the same values and the cache needs no saving.
local resistance_lookup
---@param pole LuaEntity
local function resistance(pole)
  if not resistance_lookup then
    resistance_lookup = ratings.make_resistance_lookup(shared, settings.startup, script.active_mods)
  end
  return resistance_lookup(pole.name) or 1
end

function reset_line_loss_cache()
  resistance_lookup = nil
end

-- Binary min-heap of {distance, unit_number, entity} ------------------------

local function heap_push(heap, item)
  local i = #heap + 1
  heap[i] = item
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap[parent][1] <= item[1] then break end
    heap[i], heap[parent] = heap[parent], item
    i = parent
  end
end

local function heap_pop(heap)
  local n = #heap
  local top = heap[1]
  local last = heap[n]
  heap[n] = nil
  n = n - 1
  if n > 0 then
    heap[1] = last
    local i = 1
    while true do
      local l, r = 2 * i, 2 * i + 1
      local smallest = i
      if l <= n and heap[l][1] < heap[smallest][1] then smallest = l end
      if r <= n and heap[r][1] < heap[smallest][1] then smallest = r end
      if smallest == i then break end
      heap[i], heap[smallest] = heap[smallest], heap[i]
      i = smallest
    end
  end
  return top
end

-- Job management --------------------------------------------------------------

function init_line_losses()
  storage.line_loss_queue = {}        -- slow safety round (unit numbers)
  storage.line_loss_dirty = {}        -- unit -> true: needs a search soon
  storage.line_loss_dirty_list = {}   -- the same, in order
  storage.line_loss_pending_networks = {}  -- network id -> true: changed
  storage.line_loss_input_poles = nil
  -- sink transformer unit_number -> {source transformer unit_number -> distance}
  storage.line_loss_feeders = {}
  storage.line_loss_job = nil
  -- pole unit -> {s = {source -> distance}, owner = nearest source}
  storage.pole_dist = {}
  -- source unit -> {pole unit -> true}: poles its last search reached
  storage.source_reach = {}
  -- generator unit -> {s = {transformer -> distance}, w = rated output, owner}
  storage.gen_dist = {}
  storage.gen_reach = {}
  reset_line_loss_cache()
  mark_all_line_loss_dirty()
end

-- Scheduling ------------------------------------------------------------------
-- A transformer's search is re-run soon (POLES_PER_TICK) when something on
-- its output network changed: a pole built or removed there, its network
-- merged or split (network id changed, seen by the power measurement), or a
-- transformer added or removed on it. A slow round over all transformers
-- (SAFETY_POLES_PER_TICK) catches what no event reports, such as a wire
-- added or removed inside a network without merging or splitting it.

---@param unit UnitNumber
function mark_line_loss_dirty(unit)
  local dirty = storage.line_loss_dirty
  if not dirty or dirty[unit] then return end
  dirty[unit] = true
  local list = storage.line_loss_dirty_list
  list[#list + 1] = unit
end

function mark_all_line_loss_dirty()
  local units = {}
  for unit in pairs(storage.transformers or {}) do units[#units + 1] = unit end
  table.sort(units)
  for _, unit in ipairs(units) do mark_line_loss_dirty(unit) end
end

-- Every transformer feeding this network will be re-searched. Resolved once
-- per tick, so building a blueprint of many poles costs one pass.
---@param network_id uint?
function mark_line_loss_network(network_id)
  if network_id and storage.line_loss_pending_networks then
    storage.line_loss_pending_networks[network_id] = true
  end
end

-- The input-pole index must be rebuilt (a transformer was added or removed)
function invalidate_line_loss_inputs()
  storage.line_loss_input_poles = nil
end

local function resolve_pending_networks()
  local pending = storage.line_loss_pending_networks
  if not pending or next(pending) == nil then return end
  local units = {}
  for unit, parts in pairs(storage.transformers) do
    local pole_out, pole_in = parts.pole_out, parts.pole_in
    if (pole_out and pole_out.valid and pending[pole_out.electric_network_id or 0])
      or (pole_in and pole_in.valid and pending[pole_in.electric_network_id or 0]) then
      units[#units + 1] = unit
    end
  end
  table.sort(units)
  for _, unit in ipairs(units) do mark_line_loss_dirty(unit) end
  storage.line_loss_pending_networks = {}
end

-- hidden input pole unit_number -> transformer unit_number, so a search can
-- tell which downstream transformer it has reached
local function get_input_poles()
  local input_poles = storage.line_loss_input_poles
  if input_poles then return input_poles end
  input_poles = {}
  for unit_number, transformer_parts in pairs(storage.transformers) do
    local pole_in = transformer_parts.pole_in
    if pole_in and pole_in.valid then
      input_poles[pole_in.unit_number] = unit_number
    end
  end
  storage.line_loss_input_poles = input_poles
  return input_poles
end

---@return UnitNumber?
local function pop_dirty()
  local list = storage.line_loss_dirty_list
  while #list > 0 do
    local unit = table.remove(list, 1)
    storage.line_loss_dirty[unit] = nil
    if storage.transformers[unit] then return unit end
  end
  return nil
end

---@return UnitNumber?
local function pop_safety()
  local queue = storage.line_loss_queue
  if #queue == 0 then
    for unit in pairs(storage.transformers) do queue[#queue + 1] = unit end
    table.sort(queue, function(a, b) return a > b end)  -- popped from the end: ascending
  end
  return table.remove(queue)
end

---@param unit UnitNumber
---@param urgent boolean
---@return table?
local function new_job(unit, urgent)
  local transformer_parts = storage.transformers[unit]
  local pole_out = transformer_parts and transformer_parts.pole_out
  if not (pole_out and pole_out.valid) then return nil end
  local job = {
    kind = "out",
    transformer = unit,
    urgent = urgent,
    start = pole_out.unit_number,
    heap = {},
    dist = {[pole_out.unit_number] = 0},
    done = {},
    sum = 0,
    sum_loss = 0,
    per_tile = storage.settings.per_tile,
    count = 0,
    sinks = {},
    -- Settled poles and their distances (pole ownership, heatmap)
    settled = {},
  }
  if storage.settings.machine_weighting then
    job.machine_names = line_loss_consumer_names(pole_out)
    job.seen_machines = {}
  end
  heap_push(job.heap, {0, pole_out.unit_number, pole_out})
  return job
end

-- Generator networks -----------------------------------------------------------
-- A transformer whose input network is fed by no other transformer draws
-- straight from generators. Its upstream line loss comes from a second
-- search, from its input pole outwards over that network, with each pole
-- weighted by the rated output of the generators in its supply area: a steam
-- engine far down the line costs more than one next to the transformer. The
-- loss is burned by a "Line loss" consumer on the generator network.

---@param parts table
---@return boolean
local function on_generator_network(parts)
  local in_net = parts.in_net
  if not in_net then return false end
  for _, other in pairs(storage.transformers) do
    if other.out_net == in_net then return false end
  end
  return true
end

local GENERATOR_TYPES
local function generator_types(surface)
  if GENERATOR_TYPES then return GENERATOR_TYPES end
  local wanted = {"generator", "solar-panel", "burner-generator", "fusion-generator"}
  -- Drop types this game version does not know (the filter would error)
  local ok = pcall(surface.find_entities_filtered, {type = wanted, limit = 1})
  GENERATOR_TYPES = ok and wanted or {"generator", "solar-panel", "burner-generator"}
  return GENERATOR_TYPES
end

local rated_cache = {}
---@param entity LuaEntity
---@return number  rated output (any unit, only ratios matter)
local function rated_output(entity)
  local quality = entity.quality
  local key = entity.name .. "/" .. (quality and quality.name or "normal")
  local v = rated_cache[key]
  if v then return v end
  local prototype = entity.prototype
  v = 1
  for _, getter in ipairs({"get_max_power_output", "get_max_energy_production"}) do
    local ok, result = pcall(function() return prototype[getter](quality) end)
    if ok and type(result) == "number" and result > 0 then
      v = result
      break
    end
  end
  rated_cache[key] = v
  return v
end

---@param pole LuaEntity
local function supply_distance(pole)
  local prototype = pole.prototype
  local ok, v = pcall(function() return prototype.get_supply_area_distance(pole.quality) end)
  if ok and type(v) == "number" then return v end
  ok, v = pcall(function() return prototype.supply_area_distance end)
  return (ok and type(v) == "number") and v or 2.5
end

-- Rated output of the generators in a pole's supply area, each generator
-- counted once per search (for the nearest pole reaching it)
---@param pole LuaEntity
---@param job table  records each generator's distance and rating in job.gens
---@param d number   the pole's distance
local function generator_weight(pole, job, d)
  local seen = job.seen_generators
  local p, r = pole.position, supply_distance(pole)
  local found = pole.surface.find_entities_filtered{
    area = {{p.x - r, p.y - r}, {p.x + r, p.y + r}},
    type = generator_types(pole.surface),
  }
  local w = 0
  for _, generator in pairs(found) do
    local id = generator.unit_number
    if id and not seen[id] then
      seen[id] = true
      local rated = rated_output(generator)
      w = w + rated
      job.gens[id] = {d, rated}
    end
  end
  return w
end

-- Machine weighting (opt-in setting "line-loss-machine-weighting") -------------
-- Each pole records how many machines of each type are in its supply area
-- (each machine counted once per search, for the nearest pole reaching it).
-- A machine type's live weight is its consumption on the network divided by
-- how many of it the search found, so poles are weighted by the load that is
-- actually on them right now, and an idle machine counts for almost nothing.

---@param pole_out LuaEntity
---@return string[]?  consumer prototype names on the network
function line_loss_consumer_names(pole_out)
  local names = {}
  for name in pairs(get_network_loads(pole_out, game.tick).by_name) do
    if prototypes.entity[name] then names[#names + 1] = name end
  end
  table.sort(names)
  return #names > 0 and names or nil
end

---@param pole LuaEntity
---@param job table
---@return table?  machine name -> count
local function machine_counts(pole, job)
  local names = job.machine_names
  if not names then return nil end
  local p, r = pole.position, supply_distance(pole)
  local found = pole.surface.find_entities_filtered{
    area = {{p.x - r, p.y - r}, {p.x + r, p.y + r}},
    name = names,
  }
  local counts
  local seen = job.seen_machines
  for _, machine in pairs(found) do
    local id = machine.unit_number
    if id and not seen[id] then
      seen[id] = true
      counts = counts or {}
      counts[machine.name] = (counts[machine.name] or 0) + 1
    end
  end
  return counts
end

-- Live weight per machine type: W per machine, from network consumption and
-- the counts found by the search (totals = name -> count).
---@return table?  name -> W per machine
function machine_type_weights(pole, totals, tick)
  if not (storage.settings.machine_weighting and totals and pole and pole.valid) then return nil end
  local live = get_network_loads(pole, tick).by_name
  local weights, any = {}, false
  for name, count in pairs(totals) do
    local w = live[name]
    if w and w > 0 and count > 0 then
      weights[name] = w / count
      any = true
    end
  end
  return any and weights or nil
end

-- Weighted statistics of a per-type summary {name -> {n, sd, sl, si}}:
-- mean distance, mean capped loss, mean 1/d and total weight; nil if no
-- weighted load is found in it.
function weighted_stats(types, weights)
  if not (types and weights) then return nil end
  local W, d, l, inv = 0, 0, 0, 0
  for name, x in pairs(types) do
    local w = weights[name]
    if w then
      W = W + w * x.n
      d = d + w * x.sd
      l = l + w * x.sl
      inv = inv + w * x.si
    end
  end
  if W <= 0 then return nil end
  return d / W, l / W, inv / W, W
end

-- name -> count from a per-type summary
function type_totals(types)
  local totals = {}
  for name, x in pairs(types) do totals[name] = x.n end
  return totals
end

local function add_types(types, counts, d)
  if not counts then return end
  local loss, inv = get_route_line_loss(d), 1 / math.max(d, 1)
  for name, c in pairs(counts) do
    local x = types[name]
    if not x then
      x = {n = 0, sd = 0, sl = 0, si = 0}
      types[name] = x
    end
    x.n = x.n + c
    x.sd = x.sd + c * d
    x.sl = x.sl + c * loss
    x.si = x.si + c * inv
  end
end

---@param unit UnitNumber
---@param urgent boolean
---@return table?
local function new_generator_job(unit, urgent)
  local parts = storage.transformers[unit]
  local pole_in = parts and parts.pole_in
  if not (pole_in and pole_in.valid) then return nil end
  local job = {
    kind = "gen",
    transformer = unit,
    urgent = urgent,
    start = pole_in.unit_number,
    heap = {},
    dist = {[pole_in.unit_number] = 0},
    done = {},
    settled = {},
    seen_generators = {},
    gens = {},  -- generator unit -> {distance, rated output}
  }
  heap_push(job.heap, {0, pole_in.unit_number, pole_in})
  return job
end

-- Pairing generators with transformers ----------------------------------------
-- When several transformers draw from one generator network, each generator
-- belongs to its electrically nearest transformer (ties: lower unit number).
-- Each transformer's group of generators is a source; the transformers are the
-- consumers. With "feed nearest consumers first" on, the same balancing as on
-- ordinary networks pairs them: every transformer receives its draw, every
-- group supplies its share of rated output, each pairing pulled by 1/d. A
-- transformer's upstream loss is then the flow-weighted average over the
-- generators actually feeding it. gen_region[j] summarises a transformer's own
-- generators as seen from transformer j: rated output, and output-weighted
-- distance, capped loss and 1/d.

local function generator_owner_of(entry)
  local best, best_d
  for t, d in pairs(entry.s) do
    if not best_d or d < best_d or (d == best_d and t < best) then best, best_d = t, d end
  end
  return best
end

---@param unit UnitNumber
local function rebuild_generator_region(unit)
  local parts = storage.transformers[unit]
  if not parts then return end
  local gen_dist = storage.gen_dist
  local region, own_w = {}, 0
  for id in pairs(storage.gen_reach[unit] or {}) do
    local entry = gen_dist[id]
    if entry and entry.owner == unit then
      local w = entry.w
      own_w = own_w + w
      for j, d in pairs(entry.s) do
        local r = region[j]
        if not r then
          r = {w = 0, wd = 0, wloss = 0, winv = 0}
          region[j] = r
        end
        r.w = r.w + w
        r.wd = r.wd + w * d
        r.wloss = r.wloss + w * get_route_line_loss(d)
        r.winv = r.winv + w / math.max(d, 1)
      end
    end
  end
  parts.gen_region = region
  parts.gen_own_w = own_w
end

local function rebuild_generator_regions(affected)
  local list = {}
  for unit in pairs(affected) do list[#list + 1] = unit end
  table.sort(list)
  for _, unit in ipairs(list) do rebuild_generator_region(unit) end
end

---@param unit UnitNumber  transformer whose generator search finished
---@param gens table  generator unit -> {distance, rated output}
function generator_ownership_apply(unit, gens)
  storage.gen_dist = storage.gen_dist or {}
  storage.gen_reach = storage.gen_reach or {}
  local gen_dist, reach = storage.gen_dist, storage.gen_reach
  local old = reach[unit] or {}
  local new = {}
  local affected = {[unit] = true}
  for id, item in pairs(gens) do
    new[id] = true
    local entry = gen_dist[id]
    if not entry then
      entry = {s = {}, w = item[2]}
      gen_dist[id] = entry
    end
    entry.w = item[2]
    if entry.s[unit] ~= item[1] then
      entry.s[unit] = item[1]
      if entry.owner then affected[entry.owner] = true end
    end
    local owner = generator_owner_of(entry)
    if owner ~= entry.owner then
      if entry.owner then affected[entry.owner] = true end
      affected[owner] = true
      entry.owner = owner
    end
  end
  for id in pairs(old) do
    if not new[id] then
      local entry = gen_dist[id]
      if entry then
        entry.s[unit] = nil
        if entry.owner then affected[entry.owner] = true end
        local owner = generator_owner_of(entry)
        if owner then affected[owner] = true end
        entry.owner = owner
        if not owner then gen_dist[id] = nil end
      end
    end
  end
  reach[unit] = new
  rebuild_generator_regions(affected)
end

---@param unit UnitNumber
function generator_ownership_forget(unit)
  local gen_dist, reach = storage.gen_dist, storage.gen_reach
  if not (gen_dist and reach and reach[unit]) then return end
  local affected = {}
  for id in pairs(reach[unit]) do
    local entry = gen_dist[id]
    if entry then
      entry.s[unit] = nil
      if entry.owner and entry.owner ~= unit then affected[entry.owner] = true end
      local owner = generator_owner_of(entry)
      if owner then affected[owner] = true end
      entry.owner = owner
      if not owner then gen_dist[id] = nil end
    end
  end
  reach[unit] = nil
  rebuild_generator_regions(affected)
end

-- Upstream loss of a transformer fed straight by generators: the paired value
-- when "feed nearest consumers first" is on and the pairing is fresh,
-- otherwise the average over every generator on its network.
---@param parts table
---@return number? loss, number? distance
function get_generator_loss(parts)
  if not parts.gen_loss_all then return nil end
  if storage.settings.closeness and parts.gen_loss and parts.gen_flows_tick
    and game.tick - parts.gen_flows_tick <= 2 * FLOW_PERIOD then
    return parts.gen_loss, parts.gen_distance
  end
  return parts.gen_loss_all, parts.gen_distance_all
end

---@param tick GameTick
function update_generator_flows(tick)
  local transformers = storage.transformers
  local slots = FLOW_PERIOD / FLOW_INTERVAL
  local slot = (tick / FLOW_INTERVAL) % slots
  -- Transformers drawing from each generator network (this tick's networks)
  local networks = {}
  for unit, parts in pairs(transformers) do
    local net = parts.gen_network
    if net and parts.gen_loss_all and net == parts.in_net and net % slots == slot then
      local group = networks[net]
      if not group then
        group = {}
        networks[net] = group
      end
      group[#group + 1] = unit
    end
  end
  for _, sinks in pairs(networks) do
    table.sort(sinks)
    -- Sources: transformers' own generator groups
    local sources, total_w = {}, 0
    for _, unit in ipairs(sinks) do
      local parts = transformers[unit]
      if (parts.gen_own_w or 0) > 0 and parts.gen_region then
        sources[#sources + 1] = unit
        total_w = total_w + parts.gen_own_w
      end
    end
    local demand, total_demand = {}, 0
    for j, unit in ipairs(sinks) do
      demand[j] = transformers[unit].p_draw or 0
      total_demand = total_demand + demand[j]
    end
    if #sources > 0 and total_w > 0 and total_demand > 0 then
      -- kernel K[i][j]: pull of source group i towards sink j (mean 1/d)
      local K, supply = {}, {}
      for i, owner in ipairs(sources) do
        local region = transformers[owner].gen_region
        K[i] = {}
        for j, unit in ipairs(sinks) do
          local r = region[unit]
          K[i][j] = (r and r.w > 0) and r.winv / r.w or 0
        end
        supply[i] = total_demand * transformers[owner].gen_own_w / total_w
      end
      local a, b = {}, {}
      for i = 1, #sources do a[i] = 1 end
      for j = 1, #sinks do b[j] = 1 end
      for _ = 1, 20 do  -- few transformers per generator network: always a full solve
        for i = 1, #sources do
          local sum = 0
          for j = 1, #sinks do sum = sum + K[i][j] * b[j] end
          local v = sum > 1e-9 and supply[i] / sum or 0
          a[i] = (v == v and v < math.huge) and v or 0
        end
        for j = 1, #sinks do
          local sum = 0
          for i = 1, #sources do sum = sum + K[i][j] * a[i] end
          local v = sum > 1e-9 and demand[j] / sum or 0
          b[j] = (v == v and v < math.huge) and v or 0
        end
      end
      for j, unit in ipairs(sinks) do
        local total, wloss, wd = 0, 0, 0
        for i, owner in ipairs(sources) do
          local f = a[i] * K[i][j] * b[j]
          if f == f and f < math.huge and f > 0 then
            local r = transformers[owner].gen_region[unit]
            if r and r.w > 0 then
              total = total + f
              wloss = wloss + f * r.wloss / r.w
              wd = wd + f * r.wd / r.w
            end
          end
        end
        local parts = transformers[unit]
        if total > 1e-9 then
          parts.gen_loss, parts.gen_distance = wloss / total, wd / total
          parts.gen_flows_tick = tick
        end
      end
    end
  end
end

local function finish_generator_job(job)
  local parts = storage.transformers[job.transformer]
  if not parts then return end
  local total_w = 0
  for _, item in ipairs(job.settled) do total_w = total_w + item[3] end
  local num_loss, num_d, den = 0, 0, 0
  for _, item in ipairs(job.settled) do
    -- No generators found next to any pole: spread generation evenly
    local w = total_w > 0 and item[3] or 1
    num_loss = num_loss + w * get_route_line_loss(item[2])
    num_d = num_d + w * item[2]
    den = den + w
  end
  -- Average over every generator on the network: used alone, or until the
  -- pairing below has run
  parts.gen_loss_all = den > 0 and num_loss / den or 0
  parts.gen_distance_all = den > 0 and num_d / den or 0
  parts.gen_network = parts.in_net
  generator_ownership_apply(job.transformer, job.gens)
  if storage.heatmap then heatmap_apply(-job.transformer, job.settled) end
end

-- Not (or no longer) on a generator network
---@param unit UnitNumber
local function clear_generator_loss(unit)
  local parts = storage.transformers[unit]
  if parts and (parts.gen_loss_all or parts.gen_loss) then
    parts.gen_loss, parts.gen_distance = nil, nil
    parts.gen_loss_all, parts.gen_distance_all, parts.gen_network = nil, nil, nil
    generator_ownership_forget(unit)
    heatmap_forget_source(-unit)
  end
end

local function finish_job(job, tick)
  local transformer_parts = storage.transformers[job.transformer]
  if transformer_parts then
    -- Keep the reverse index (who feeds each downstream transformer) in step
    storage.line_loss_feeders = storage.line_loss_feeders or {}
    local feeders = storage.line_loss_feeders
    for _, sink in pairs(transformer_parts.line_sinks or {}) do
      local f = feeders[sink.unit]
      if f then f[job.transformer] = nil end
    end
    for _, sink in pairs(job.sinks) do
      feeders[sink.unit] = feeders[sink.unit] or {}
      feeders[sink.unit][job.transformer] = sink.d
    end
    -- Keep the existing table when nothing changed, so caches keyed on it
    -- (closeness kernel) stay valid between search passes
    local old = transformer_parts.line_sinks
    local same = old and #old == #job.sinks
    if same then
      for x = 1, #old do
        if old[x].unit ~= job.sinks[x].unit or old[x].d ~= job.sinks[x].d then same = false break end
      end
    end
    if not same then transformer_parts.line_sinks = job.sinks end
    transformer_parts.line_sum_d = job.sum
    -- Mean capped loss over the poles (machines are spread over them), valid
    -- for the per-tile setting it was computed with
    transformer_parts.line_sum_loss = job.sum_loss
    transformer_parts.line_sum_loss_per_tile = job.per_tile
    transformer_parts.line_n = job.count
    -- Machines per type over the whole network (machine weighting)
    local types, any = {}, false
    for _, item in ipairs(job.settled) do
      if item[3] then
        add_types(types, item[3], item[2])
        any = true
      end
    end
    transformer_parts.line_types = any and types or nil
    update_line_distance(transformer_parts, tick)
    pole_ownership_apply(job.transformer, job.settled)
    if storage.heatmap then heatmap_apply(job.transformer, job.settled) end
  end
end

-- Settles poles until the heap is empty or the budget runs out.
---@return integer remaining budget
local function step_job(job, budget, tick)
  local heap, dist, done = job.heap, job.dist, job.done
  while budget > 0 and #heap > 0 do
    local item = heap_pop(heap)
    local d, unit_number, pole = item[1], item[2], item[3]
    if not done[unit_number] and pole.valid then
      done[unit_number] = true
      budget = budget - 1
      local hidden = is_hidden(pole)
      if job.kind == "gen" then
        if not hidden then
          job.settled[#job.settled + 1] = {pole, d, generator_weight(pole, job, d)}
        end
      elseif not hidden then
        job.sum = job.sum + d
        job.sum_loss = job.sum_loss + get_route_line_loss(d)
        job.count = job.count + 1
        local settled = job.settled
        if settled then settled[#settled + 1] = {pole, d, machine_counts(pole, job)} end
      elseif pole.name == HIDDEN_INPUT_POLE then
        -- Another transformer's input: a consumer on this network
        local sink = get_input_poles()[unit_number]
        if sink and sink ~= job.transformer then
          job.sinks[#job.sinks + 1] = {unit = sink, d = d}
        end
      end
      -- Hidden poles (other transformers' inputs, alt-surface poles) are
      -- endpoints: the network does not continue through them.
      if unit_number == job.start or not hidden then
        local connector = pole.get_wire_connector(defines.wire_connector_id.pole_copper, false)
        if connector then
          local r1 = resistance(pole)
          local p1 = pole.position
          for _, connection in pairs(connector.connections) do
            local other = connection.target.owner
            if other.valid and other.type == "electric-pole" then
              local other_unit_number = other.unit_number
              if not done[other_unit_number] then
                local p2 = other.position
                local dx, dy = p2.x - p1.x, p2.y - p1.y
                local weight = math.sqrt(dx * dx + dy * dy) * 0.5 * (r1 + resistance(other))
                local new_d = d + weight
                local best = dist[other_unit_number]
                if not best or new_d < best then
                  dist[other_unit_number] = new_d
                  heap_push(heap, {new_d, other_unit_number, other})
                end
              end
            end
          end
        end
      end
    end
  end
  if #heap == 0 then
    if job.kind == "gen" then
      finish_generator_job(job)
    else
      finish_job(job, tick)
    end
    job.finished = true
  end
  return budget
end

---@param tick GameTick
function update_line_losses(tick)
  if not storage.settings.enabled then return end
  -- Saves from before a field existed (the mod updated without a version
  -- change): set up what is missing and search everything again
  if not storage.line_loss_dirty_list then
    init_line_losses()
  elseif not storage.pole_dist then
    storage.pole_dist, storage.source_reach = {}, {}
    mark_all_line_loss_dirty()
  end
  if tick % FLOW_INTERVAL == 0 and storage.settings.closeness then
    update_closeness_flows(tick)
    update_generator_flows(tick)
  end
  resolve_pending_networks()

  local job = storage.line_loss_job
  local has_dirty = #storage.line_loss_dirty_list > 0
  if job and not job.urgent and has_dirty then
    -- A change is waiting: put the safety search back and do that first
    table.insert(storage.line_loss_queue, 1, job.transformer)
    job = nil
    storage.line_loss_job = nil
  end
  local urgent = has_dirty or (job and job.urgent)
  local budget = urgent and POLES_PER_TICK or SAFETY_POLES_PER_TICK
  -- Bounded so that a run of transformers with tiny networks cannot spin
  local starts = 0
  while budget > 0 and starts < 10 do
    if not job then
      local unit = pop_dirty()
      if unit then
        job = new_job(unit, true)
      else
        unit = pop_safety()
        if not unit then return end
        job = new_job(unit, false)
      end
      starts = starts + 1
      storage.line_loss_job = job
    end
    if job then
      budget = step_job(job, budget, tick)
      if job.finished then
        local finished = job
        job = nil
        storage.line_loss_job = nil
        -- After its output search, a transformer drawing straight from
        -- generators also searches its input network
        if finished.kind == "out" then
          local parts = storage.transformers[finished.transformer]
          if parts and on_generator_network(parts) then
            job = new_generator_job(finished.transformer, finished.urgent)
            storage.line_loss_job = job
          else
            clear_generator_loss(finished.transformer)
          end
        end
      end
    end
  end
end

-- Pole ownership (used by "feed nearest consumers first") -------------------
-- Each pole belongs to the source transformer electrically closest to it
-- (shortest resistance-weighted distance; ties go to the lower unit number).
-- The machines powered near a pole are then charged to that source, at that
-- source's distance: feeding a network from several sides cuts the loss of
-- its directly powered machines. For each source, region[j] summarises its
-- own poles as seen from source j (sum of distances, sum of capped route
-- losses, count), which gives the distance and loss from any source on the
-- network to this source's share of the machines.

local function owner_of(entry)
  local best, best_d
  for source, d in pairs(entry.s) do
    if not best_d or d < best_d or (d == best_d and source < best) then
      best, best_d = source, d
    end
  end
  return best
end

local function same_region(a, b)
  if not a then return false end
  for j, x in pairs(a) do
    local y = b[j]
    if not y or x.n ~= y.n or x.sum_d ~= y.sum_d or x.sum_loss ~= y.sum_loss or x.sum_inv ~= y.sum_inv
      or x.tn ~= y.tn or x.tsd ~= y.tsd then return false end
  end
  for j in pairs(b) do
    if not a[j] then return false end
  end
  return true
end

---@param source UnitNumber
local function rebuild_region(source)
  local parts = storage.transformers[source]
  if not parts then return end
  local pole_dist = storage.pole_dist
  local region, n = {}, 0
  for unit in pairs(storage.source_reach[source] or {}) do
    local entry = pole_dist[unit]
    if entry and entry.owner == source then
      n = n + 1
      for j, d in pairs(entry.s) do
        local r = region[j]
        if not r then
          r = {sum_d = 0, sum_loss = 0, sum_inv = 0, n = 0}
          region[j] = r
        end
        r.sum_d = r.sum_d + d
        r.sum_loss = r.sum_loss + get_route_line_loss(d)
        r.sum_inv = r.sum_inv + 1 / math.max(d, 1)
        if entry.m then
          r.t = r.t or {}
          add_types(r.t, entry.m, d)
          for _, c in pairs(entry.m) do
            r.tn = (r.tn or 0) + c
            r.tsd = (r.tsd or 0) + c * d
          end
        end
        r.n = r.n + 1
      end
    end
  end
  -- Keep the old table when nothing changed, so the cached kernel stays valid
  if not same_region(parts.region, region) then parts.region = region end
  parts.own_n = n
end

-- Updates pole ownership after a search; rebuilds the regions of every
-- source whose poles or distances changed.
---@param source UnitNumber
---@param settled table  {{pole, distance}, ...}
function pole_ownership_apply(source, settled)
  local pole_dist = storage.pole_dist
  local reach = storage.source_reach
  if not (pole_dist and reach) then return end
  local old = reach[source] or {}
  local new = {}
  local affected = {[source] = true}
  for _, item in ipairs(settled) do
    local pole, d = item[1], item[2]
    if pole.valid then
      local unit = pole.unit_number
      new[unit] = true
      local entry = pole_dist[unit]
      if not entry then
        entry = {s = {}}
        pole_dist[unit] = entry
      end
      entry.m = item[3]
      entry.pole = pole  -- for the loss map
      if entry.s[source] ~= d then
        entry.s[source] = d
        -- the owner's region, as seen from this source, changed
        if entry.owner then affected[entry.owner] = true end
      end
      local owner = owner_of(entry)
      if owner ~= entry.owner then
        if entry.owner then affected[entry.owner] = true end
        affected[owner] = true
        entry.owner = owner
      end
    end
  end
  for unit in pairs(old) do
    if not new[unit] then
      local entry = pole_dist[unit]
      if entry then
        entry.s[source] = nil
        if entry.owner then affected[entry.owner] = true end
        local owner = owner_of(entry)
        if owner then affected[owner] = true end
        entry.owner = owner
        if not owner then pole_dist[unit] = nil end
      end
    end
  end
  reach[source] = new
  local list = {}
  for unit in pairs(affected) do list[#list + 1] = unit end
  table.sort(list)
  for _, unit in ipairs(list) do rebuild_region(unit) end
end

-- A source transformer was removed: its poles go to the next nearest source
---@param source UnitNumber
function pole_ownership_forget_source(source)
  local pole_dist = storage.pole_dist
  local reach = storage.source_reach
  if not (pole_dist and reach and reach[source]) then return end
  local affected = {}
  for unit in pairs(reach[source]) do
    local entry = pole_dist[unit]
    if entry then
      entry.s[source] = nil
      if entry.owner ~= source and entry.owner then affected[entry.owner] = true end
      local owner = owner_of(entry)
      if owner then affected[owner] = true end
      entry.owner = owner
      if not owner then pole_dist[unit] = nil end
    end
  end
  reach[source] = nil
  local list = {}
  for unit in pairs(affected) do list[#list + 1] = unit end
  table.sort(list)
  for _, unit in ipairs(list) do rebuild_region(unit) end
end

-- Mean line loss of the machines' share: the average of each pole's capped
-- route loss. Until the next search after a change of the per-tile setting,
-- falls back to the loss of the mean pole distance.
---@return number
local function mean_pole_loss(parts, tick)
  local n = parts.line_n
  if not n or n == 0 then return 0 end
  local weights = machine_type_weights(parts.pole_out, parts.line_types and type_totals(parts.line_types), tick or game.tick)
  local _, wl = weighted_stats(parts.line_types, weights)
  if wl then return wl end
  if parts.line_sum_loss and parts.line_sum_loss_per_tile == storage.settings.per_tile then
    return parts.line_sum_loss / n
  end
  return get_route_line_loss(parts.line_sum_d / n)
end

-- Recomputes D and the line loss from the cached distances and the current
-- power flows. The loss is capped per route and then averaged, so one very
-- long route does not drag the source's other routes up to the cap.
-- Called when a search finishes and after every power measurement.
---@param transformer_parts TransformerData
---@param tick GameTick
function update_line_distance(transformer_parts, tick)
  if not storage.settings.enabled then return end
  local n = transformer_parts.line_n
  if not n then return end  -- not searched yet
  local sinks = transformer_parts.line_sinks or {}
  local transformers = storage.transformers

  local num, num_loss, den = 0, 0, 0
  for _, sink in pairs(sinks) do
    local sink_parts = transformers[sink.unit]
    local p = sink_parts and sink_parts.p_draw or 0
    num = num + p * sink.d
    num_loss = num_loss + p * get_route_line_loss(sink.d)
    den = den + p
  end

  local p_rest = 0
  local pole_out = transformer_parts.pole_out
  if n > 0 and pole_out and pole_out.valid then
    -- Machines only: downstream transformers are counted above, and the loss
    -- consumers are the loss itself
    p_rest = get_network_loads(pole_out, tick).machines
  end
  local mean_pole_d = n > 0 and transformer_parts.line_sum_d / n or 0
  local pole_loss = mean_pole_loss(transformer_parts, tick)
  do
    -- Machine weighting: the machines' distance follows where the load is
    local weights = machine_type_weights(pole_out, transformer_parts.line_types and type_totals(transformer_parts.line_types), tick)
    local wd = weighted_stats(transformer_parts.line_types, weights)
    if wd then mean_pole_d = wd end
  end
  -- Total load on the output network, used to split this transformer's
  -- output among its consumers (grid-diagram.lua)
  transformer_parts.line_load_total = den + p_rest

  -- Closeness-weighted flows (opt-in) set D themselves for every source on
  -- the network; only fall back to proportional sharing when they are stale
  if storage.settings.closeness and transformer_parts.line_flows
    and tick - (transformer_parts.line_flows_tick or -math.huge) <= 2 * FLOW_PERIOD then
    return
  end

  if den + p_rest > 0 then
    transformer_parts.line_distance = (num + p_rest * mean_pole_d) / (den + p_rest)
    transformer_parts.line_loss = (num_loss + p_rest * pole_loss) / (den + p_rest)
  elseif n > 0 then
    -- No load at all: fall back to the plain mean so the readout is not 0
    transformer_parts.line_distance = mean_pole_d
    transformer_parts.line_loss = pole_loss
  elseif #sinks > 0 then
    local total, total_loss = 0, 0
    for _, sink in pairs(sinks) do
      total = total + sink.d
      total_loss = total_loss + get_route_line_loss(sink.d)
    end
    transformer_parts.line_distance = total / #sinks
    transformer_parts.line_loss = total_loss / #sinks
  else
    transformer_parts.line_distance = 0
    transformer_parts.line_loss = 0
  end
end

-- Closeness-weighted flows (opt-in setting "line-loss-closeness")
-- ---------------------------------------------------------------------------
-- Proportional sharing assumes every source feeds every consumer of its
-- network in the same proportions. With this option, power is assigned to the
-- consumers nearer each source instead: for each network the flows f_ik from
-- source i to consumer k satisfy
--   sum_k f_ik = P_i   (each source delivers what it was measured to deliver)
--   sum_i f_ik = Q_k   (each consumer receives what it was measured to draw)
--   f_ik = a_i * K_ik * b_k,  K_ik = 1 / d_ik  (current divides inversely with
--                                               resistance)
-- a and b come from Sinkhorn balancing (alternately rescaling rows and
-- columns). Consumers are the downstream transformers plus the machines,
-- split into one pseudo-consumer per source: the machines on the poles that
-- source is electrically closest to (see Pole ownership), sized by its share
-- of the network's poles.
-- Demands are scaled to the transformers' total supply, since generators wired
-- directly into the network may cover part of the load.
-- D_i = sum_k f_ik * d_ik / P_i, so each source pays for where its power goes.
--
-- Scaling to networks with tens of sources and consumers:
--   * each network is rebalanced every FLOW_PERIOD ticks, staggered by
--     network id, so networks never all update on the same tick;
--   * the scaling factors a, b are kept between updates (warm start). Loads
--     change slowly, so a few iterations from the previous solution are
--     enough; a cold start runs the full count;
--   * the kernel is sparse (nearest pairs only), so the cost per update grows
--     with sources + consumers rather than their product.

FLOW_INTERVAL = 60          -- how often the scheduler runs
FLOW_PERIOD = 300     -- how often each network is rebalanced
local COLD_ITERATIONS = 20
local WARM_ITERATIONS = 3
-- Sparse kernel: each source keeps its NEAREST_SINKS nearest consumers, and
-- each consumer its NEAREST_SOURCES nearest sources (so none is left unfed).
-- Under 1/d the far pairs carry little power anyway; dropping them keeps the
-- cost proportional to (sources + consumers) instead of their product.
local TINY = 1e-9  -- below this a sum is treated as zero (avoids 0 * inf = NaN)
local NEAREST_SINKS = 8
local NEAREST_SOURCES = 3
local REST = "rest"

---@param tick GameTick
-- Sparse kernel per network, rebuilt only when the network's sources or their
-- distances change (finish_job keeps a source's line_sinks table when its
-- contents did not change). Derived purely from storage, so it is a cache:
-- after loading a save it is rebuilt with identical results.
local kernel_cache = {}

-- Column keys: a downstream transformer's unit number; "r<unit>" for the
-- machines on the poles that source owns; REST for all the network's machines
-- when no pole ownership is known yet (each source at its mean pole distance).
local function sink_key_less(x, y)
  local tx, ty = type(x), type(y)
  if tx ~= ty then return tx == "number" end
  return x < y
end

local function build_kernel(sources, transformers)
  local in_network = {}
  for _, unit in ipairs(sources) do in_network[unit] = true end
  -- Regions (machines on each source's own poles), if ownership is known
  local regions = {}  -- key -> owner source unit
  for _, unit in ipairs(sources) do
    local parts = transformers[unit]
    if (parts.own_n or 0) > 0 and parts.region then regions["r" .. unit] = unit end
  end
  local use_regions = next(regions) ~= nil

  local sink_set, by_sink, rows, dists = {}, {}, {}, {}
  for i, unit in ipairs(sources) do
    local parts = transformers[unit]
    local list = {}
    for _, sink in pairs(parts.line_sinks or {}) do list[#list + 1] = {key = sink.unit, d = sink.d} end
    if use_regions then
      for key, owner in pairs(regions) do
        local r = transformers[owner].region[unit]
        -- Pull: the average of 1/d over the region's poles, as current
        -- divides at each pole, rather than 1 / (mean distance)
        if r and r.n > 0 then list[#list + 1] = {key = key, d = r.sum_d / r.n, k = r.sum_inv / r.n} end
      end
    end
    table.sort(list, function(x, y) if x.d ~= y.d then return x.d < y.d end return sink_key_less(x.key, y.key) end)
    local row, d_of = {}, {}
    for x, item in ipairs(list) do
      sink_set[item.key] = true
      d_of[item.key] = item.d
      local k = item.k or 1 / math.max(item.d, 1)
      if x <= NEAREST_SINKS then row[item.key] = k end
      local s = by_sink[item.key]
      if not s then s = {}; by_sink[item.key] = s end
      s[#s + 1] = {item.d, i, k}
    end
    local own = "r" .. unit
    if regions[own] and d_of[own] then
      local r = parts.region[unit]
      row[own] = r.sum_inv / r.n  -- always paired with its own poles
    end
    if not use_regions and parts.line_n > 0 then
      d_of[REST] = parts.line_sum_d / parts.line_n
      row[REST] = 1 / math.max(d_of[REST], 1)
    end
    rows[i], dists[i] = row, d_of
  end
  for key, s in pairs(by_sink) do
    table.sort(s, function(x, y) if x[1] ~= y[1] then return x[1] < y[1] end return x[2] < y[2] end)
    for x = 1, math.min(NEAREST_SOURCES, #s) do
      rows[s[x][2]][key] = s[x][3]
    end
  end

  local sink_order = {}
  for k in pairs(sink_set) do sink_order[#sink_order + 1] = k end
  table.sort(sink_order, sink_key_less)
  if not use_regions then sink_order[#sink_order + 1] = REST end
  local sink_index = {}
  for j, k in ipairs(sink_order) do sink_index[k] = j end

  -- Same entries, as arrays by row and by column, plus each entry's distance
  local row_j, row_v, row_d, col_i, col_v = {}, {}, {}, {}, {}
  for j = 1, #sink_order do col_i[j], col_v[j] = {}, {} end
  for i in ipairs(sources) do
    local keys = {}
    for k in pairs(rows[i]) do keys[#keys + 1] = sink_index[k] end
    table.sort(keys)
    local rj, rv, rd = {}, {}, {}
    for _, j in ipairs(keys) do
      local k = sink_order[j]
      local kv = rows[i][k]
      rj[#rj + 1], rv[#rv + 1], rd[#rd + 1] = j, kv, dists[i][k]
      local ci, cv = col_i[j], col_v[j]
      ci[#ci + 1], cv[#cv + 1] = i, kv
    end
    row_j[i], row_v[i], row_d[i] = rj, rv, rd
  end
  return {sink_order = sink_order, regions = regions, row_j = row_j, row_v = row_v, row_d = row_d, col_i = col_i, col_v = col_v}
end

-- The cached kernel is still valid if the network has the same sources with
-- the same distance tables (compared by identity) and pole sums.
local function kernel_signature(sources, transformers)
  local sig = {}
  for i, unit in ipairs(sources) do
    local parts = transformers[unit]
    sig[i] = {parts.line_sinks, parts.line_sum_d, parts.line_n, parts.region or false, parts.own_n or 0}
  end
  return sig
end

local function same_signature(a, b, sources, cached_sources)
  if not a or #a ~= #b or #sources ~= #cached_sources then return false end
  for i = 1, #a do
    if sources[i] ~= cached_sources[i] then return false end
    local x, y = a[i], b[i]
    for k = 1, 5 do
      if x[k] ~= y[k] then return false end
    end
  end
  return true
end

---@param tick GameTick
function update_closeness_flows(tick)
  local transformers = storage.transformers
  storage.line_loss_flow_state = storage.line_loss_flow_state or {}
  local flow_state = storage.line_loss_flow_state
  local slots = FLOW_PERIOD / FLOW_INTERVAL
  local slot = (tick / FLOW_INTERVAL) % slots

  -- Group sources by the network they feed (only this tick's networks)
  local networks = {}
  for unit, parts in pairs(transformers) do
    local pole_out = parts.pole_out
    if parts.line_n and pole_out and pole_out.valid then
      local network_id = pole_out.electric_network_id
      if network_id and network_id % slots == slot then
        local group = networks[network_id]
        if not group then
          group = {sources = {}, pole = pole_out}
          networks[network_id] = group
        end
        group.sources[#group.sources + 1] = unit
      end
    end
  end

  for network_id, group in pairs(networks) do
    local sources = group.sources
    table.sort(sources)  -- deterministic order

    local signature = kernel_signature(sources, transformers)
    local cached = kernel_cache[network_id]
    if not (cached and same_signature(signature, cached.signature, sources, cached.sources)) then
      cached = build_kernel(sources, transformers)
      cached.signature, cached.sources = signature, {table.unpack(sources)}
      kernel_cache[network_id] = cached
    end
    local sink_order, row_j, row_v, row_d = cached.sink_order, cached.row_j, cached.row_v, cached.row_d
    local col_i, col_v = cached.col_i, cached.col_v
    local n_sources, n_sinks = #sources, #sink_order
    local regions = cached.regions

    -- Machine weighting: live weight per machine type on this network, and
    -- each region's pull and distance from where its load actually is (on a
    -- copy of the cached kernel values)
    local weights
    if storage.settings.machine_weighting then
      local first = transformers[sources[1]]
      weights = first and first.line_types and machine_type_weights(group.pole, type_totals(first.line_types), tick)
    end
    if weights then
      local new_row_v, new_row_d, new_col_i, new_col_v = {}, {}, {}, {}
      for j = 1, n_sinks do new_col_i[j], new_col_v[j] = {}, {} end
      for i, unit in ipairs(sources) do
        local rj, rv, rd = row_j[i], row_v[i], row_d[i]
        local nv, nd = {}, {}
        for x = 1, #rj do
          local k = sink_order[rj[x]]
          local v, d = rv[x], rd[x]
          if regions[k] then
            local region = transformers[regions[k]].region
            local r = region and region[unit]
            local wd, _, winv = weighted_stats(r and r.t, weights)
            if wd then v, d = winv, wd end
          end
          nv[x], nd[x] = v, d
          local ci, cv = new_col_i[rj[x]], new_col_v[rj[x]]
          ci[#ci + 1], cv[#cv + 1] = i, v
        end
        new_row_v[i], new_row_d[i] = nv, nd
      end
      row_v, row_d, col_i, col_v = new_row_v, new_row_d, new_col_i, new_col_v
    end

    -- Measured supplies and demands
    local supply, total_supply = {}, 0
    for i, unit in ipairs(sources) do
      local p = transformers[unit].p_deliv or 0  -- after its own line loss
      supply[i] = p
      total_supply = total_supply + p
    end
    -- Machines: split over the sources' regions by how many poles each owns,
    -- or, with machine weighting, by the live load on those poles
    local machines = get_network_loads(group.pole, tick).machines
    local own = {}
    local total_own = 0
    if weights then
      for key, owner in pairs(regions) do
        local region = transformers[owner].region
        local r = region and region[owner]
        local _, _, _, W = weighted_stats(r and r.t, weights)
        own[key] = W or 0
        total_own = total_own + own[key]
      end
    end
    if total_own <= 0 then
      total_own = 0
      for key, owner in pairs(regions) do
        own[key] = transformers[owner].own_n or 0
        total_own = total_own + own[key]
      end
    end
    local demand, total_demand = {}, 0
    for j, k in ipairs(sink_order) do
      local p
      if k == REST then
        p = machines
      elseif regions[k] then
        p = total_own > 0 and machines * own[k] / total_own or 0
      else
        local sink_parts = transformers[k]
        p = sink_parts and sink_parts.p_draw or 0
      end
      demand[j] = p
      total_demand = total_demand + p
    end

    if total_supply > 0 and total_demand > 0 then
      -- Generators wired straight into the network may cover part of the
      -- load, so the consumers' demand is scaled to the transformers' supply
      local scale = total_supply / total_demand
      for j = 1, n_sinks do demand[j] = demand[j] * scale end

      -- Warm start from this network's previous factors when available
      local previous = flow_state[network_id]
      local a, b, warm = {}, {}, previous ~= nil
      for i, unit in ipairs(sources) do
        local v = previous and previous.a[unit]
        if not v then warm = false end
        a[i] = v or 1
      end
      for j, k in ipairs(sink_order) do
        local v = previous and previous.b[k]
        if not v then warm = false end
        b[j] = v or 1
      end

      for _ = 1, warm and WARM_ITERATIONS or COLD_ITERATIONS do
        for i = 1, n_sources do
          local rj, rv, s = row_j[i], row_v[i], 0
          for x = 1, #rj do s = s + rv[x] * b[rj[x]] end
          local v = s > TINY and supply[i] / s or 0
          a[i] = (v == v and v < math.huge) and v or 0
        end
        for j = 1, n_sinks do
          local ci, cv, s = col_i[j], col_v[j], 0
          for x = 1, #ci do s = s + cv[x] * a[ci[x]] end
          local v = s > TINY and demand[j] / s or 0
          b[j] = (v == v and v < math.huge) and v or 0
        end
      end

      -- Flows, each source's D, and the factors for the next warm start
      local a_by, b_by = {}, {}
      for j, k in ipairs(sink_order) do b_by[k] = b[j] end
      for i, unit in ipairs(sources) do
        a_by[unit] = a[i]
        local parts = transformers[unit]
        local rj, rv, rd = row_j[i], row_v[i], row_d[i]
        local pole_loss = mean_pole_loss(parts, tick)
        local flows, total, weighted, weighted_loss = {}, 0, 0, 0
        for x = 1, #rj do
          local f = a[i] * rv[x] * b[rj[x]]
          if not (f == f and f < math.huge) then f = 0 end
          local k = sink_order[rj[x]]
          flows[k] = f
          total = total + f
          weighted = weighted + f * rd[x]
          -- Each route capped on its own: a region at the mean of its poles'
          -- capped losses from this source
          local route_loss
          if k == REST then
            route_loss = pole_loss
          elseif regions[k] then
            local r = transformers[regions[k]].region[unit]
            local _, wl = weighted_stats(r and r.t, weights)
            route_loss = wl or (r and r.n > 0 and r.sum_loss / r.n) or get_route_line_loss(rd[x])
          else
            route_loss = get_route_line_loss(rd[x])
          end
          weighted_loss = weighted_loss + f * route_loss
        end
        parts.line_flows = flows
        parts.line_flows_tick = tick
        local d = total > TINY and weighted / total
        if d and d == d and d < math.huge then parts.line_distance = d end
        local loss = total > TINY and weighted_loss / total
        if loss and loss == loss and loss < math.huge then parts.line_loss = loss end
      end
      flow_state[network_id] = {a = a_by, b = b_by, tick = tick}
    end
  end

  -- Forget networks that no longer exist (merged, split, removed)
  if slot == 0 then
    for network_id, state in pairs(flow_state) do
      if tick - state.tick > 4 * FLOW_PERIOD then
        flow_state[network_id] = nil
        kernel_cache[network_id] = nil
      end
    end
  end
end

-- Line loss for a single route of the given distance (capped).
---@param distance number
---@return number
function get_route_line_loss(distance)
  local loss = distance * storage.settings.per_tile / 100
  if loss ~= loss or loss < 0 then return 0 end
  if loss > LINE_LOSS_MAX then loss = LINE_LOSS_MAX end
  return loss
end

-- Line loss of the power arriving at a transformer from upstream (display
-- only: the loss itself is charged at the transformers feeding the network).
-- Under proportional sharing this transformer receives each source's power
-- in proportion to that source's output, so the arriving power's loss is the
-- power-weighted mean of the (individually capped) routes from those sources.
---@param unit_number UnitNumber
---@return number? loss, number? distance  nil when nothing feeds it through a transformer
function get_upstream_line_loss(unit_number)
  local s = storage.settings
  if not s.enabled then return nil end
  local feeders = storage.line_loss_feeders and storage.line_loss_feeders[unit_number]
  if not feeders or next(feeders) == nil then
    -- Fed straight by generators
    local parts = storage.transformers[unit_number]
    if parts then return get_generator_loss(parts) end
    return nil
  end
  local transformers = storage.transformers
  local num, num_loss, den, sum_d, sum_loss, count = 0, 0, 0, 0, 0, 0
  for source, d in pairs(feeders) do
    local source_parts = transformers[source]
    if source_parts then
      local p = source_parts.p_deliv or 0
      local flows = s.closeness and source_parts.line_flows
      if flows then p = flows[unit_number] or 0 end
      local route_loss = get_route_line_loss(d)
      num = num + p * d
      num_loss = num_loss + p * route_loss
      den = den + p
      sum_d = sum_d + d
      sum_loss = sum_loss + route_loss
      count = count + 1
    end
  end
  if count == 0 then return nil end
  local distance = den > 0 and num / den or sum_d / count
  local loss = den > 0 and num_loss / den or sum_loss / count
  if distance ~= distance or loss ~= loss then return nil end
  return loss, distance
end

-- Fraction of energy that survives the line, for a transformer.
---@param transformer_parts TransformerData
---@return number
function get_line_factor(transformer_parts)
  local s = storage.settings
  if not s.enabled then return 1 end
  local loss = transformer_parts.line_loss or 0
  -- NaN fails every comparison, so test for it explicitly
  if loss ~= loss or loss < 0 then
    transformer_parts.line_loss = nil  -- recomputed on the next pass
    return 1
  end
  if loss > LINE_LOSS_MAX then loss = LINE_LOSS_MAX end
  return 1 - loss
end
