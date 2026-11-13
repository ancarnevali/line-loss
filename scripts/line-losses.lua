-- Searches over the wire graph, one transformer at a time, after its network
-- changed. From a transformer's output: the poles it reaches (pole
-- ownership: each pole belongs to its nearest transformer, whose network
-- load spreads over it), the machines near them (machine weighting), the
-- downstream transformers (feeders), and its shortest-path tree (feeder
-- highlight). From the input of a transformer fed straight by generators:
-- the generators and their rated output per pole (gen_tree). Losses
-- themselves come from kirchhoff.lua; the getters below read them.
--
-- Resistance-weighted distances: each wire's length times the mean
-- resistance of its two poles, r = sqrt(P_big / P_pole).
--
-- UPS: searches settle at most POLES_PER_TICK poles per tick and read the
-- wires from a cached wire graph (storage.wire_graph); a slow sweep checks
-- SWEEP_POLES_PER_TICK cached poles per tick against the game.

local POLES_PER_TICK = 100       -- searches after a change
local SWEEP_POLES_PER_TICK = 20  -- wire-graph check: wire counts (3 reads per pole)
local SWEEP_FULL_PER_TICK = 1    -- wire-graph check: every wire's far end
local LINE_LOSS_MAX = 0.95  -- the line keeps at least 5% of the power
local HIDDEN_PREFIX = "po-hidden-"
local HIDDEN_INPUT_POLE = "po-hidden-electric-pole-in"

-- Resistance per tile, relative to the big electric pole (= 1), from Power
-- Overload's pole ratings (ratings.lua). Unrated poles count as 1. Derived
-- only from startup settings and the active mods, so every client computes
-- the same values and the cache needs no saving.
local resistance_lookup

-- Per prototype name: {hidden, pole, r} = Power Overload's hidden entity,
-- an electric pole, resistance per tile. Read once per prototype, so a search
-- reads only the name of each pole it meets. Derived from prototypes and
-- startup settings only, like the resistance: no saving needed.
local prototype_info = {}
---@param name string
local function info_of(name)
  local info = prototype_info[name]
  if not info then
    if not resistance_lookup then
      resistance_lookup = ratings.make_resistance_lookup(shared, settings.startup, script.active_mods)
    end
    local prototype = prototypes.entity[name]
    info = {
      hidden = string.sub(name, 1, #HIDDEN_PREFIX) == HIDDEN_PREFIX,
      pole = prototype ~= nil and prototype.type == "electric-pole",
      r = resistance_lookup(name) or 1,
    }
    -- Pole class for the mixed-wire rule: transmission (resistance of a big
    -- pole or less) or distribution (medium, small, substation)
    if info.pole and not info.hidden then
      info.class = info.r <= 1 + 1e-9 and "transmission" or "distribution"
    end
    prototype_info[name] = info
  end
  return info
end

-- Line resistance of a pole prototype (big pole = 1; hidden poles 1)
function line_loss_resistance(name)
  return info_of(name).r
end

-- A wire straight from a transmission pole to a distribution pole (medium,
-- small, substation), not through a transformer: its resistance is multiplied
-- by the "mixed wires" setting
---@return boolean
function line_loss_mixed_wire(name_a, name_b)
  local a, b = info_of(name_a).class, info_of(name_b).class
  return a ~= nil and b ~= nil and a ~= b
end

function reset_line_loss_cache()
  resistance_lookup = nil
  prototype_info = {}
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
  storage.line_loss_queue = nil       -- old safety round (before 0.1.5)
  storage.wire_graph = {}             -- pole unit -> cached wires (see below)
  storage.wire_sweep_list = nil
  storage.wire_sweep_pos = 1
  storage.line_loss_dirty = {}        -- unit -> true: needs a search soon
  storage.line_loss_dirty_list = {}   -- the same, in order
  storage.line_loss_dirty_head = 1    -- next one to search
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
  storage.gen_dist = nil              -- before 0.2.0
  storage.gen_reach = nil
  reset_line_loss_cache()
  mark_all_line_loss_dirty()
end

-- Scheduling ------------------------------------------------------------------
-- A transformer's search is re-run soon (POLES_PER_TICK) when something on
-- its downstream network changed: a pole built or removed there, its network
-- merged or split (network id changed, seen by the power measurement), or a
-- transformer added or removed on it; for a transformer fed straight by
-- generators, also its upstream network. The wire-graph sweep catches what no
-- event reports, such as a wire added or removed inside a network without
-- merging or splitting it, and queues that network.

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
  -- An upstream network matters only to a transformer fed straight by
  -- generators (no transformer feeds it): its generator search covers it
  local fed = {}
  for _, parts in pairs(storage.transformers) do
    if parts.out_net then fed[parts.out_net] = true end
  end
  for unit, parts in pairs(storage.transformers) do
    -- The network ids kept by update_transformers; read from the poles only
    -- until its first pass. An id that changed since then (networks merged
    -- or split) is caught there within a second and searched again.
    local out_net, in_net = parts.out_net, parts.in_net
    if out_net == nil then
      local pole_out = parts.pole_out
      out_net = pole_out and pole_out.valid and pole_out.electric_network_id
    end
    if in_net == nil then
      local pole_in = parts.pole_in
      in_net = pole_in and pole_in.valid and pole_in.electric_network_id
    end
    -- (or was, until now: its generator loss must be cleared)
    if pending[out_net or 0] or (pending[in_net or 0] and (not fed[in_net] or parts.gen_fed)) then
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
  -- First in, first out: a read position instead of shifting the list.
  -- The list is emptied as soon as it is used up, so #list > 0 still means
  -- "something is waiting".
  local list = storage.line_loss_dirty_list
  local head = storage.line_loss_dirty_head or 1
  local n = #list
  local found
  while head <= n and not found do
    local unit = list[head]
    head = head + 1
    storage.line_loss_dirty[unit] = nil
    if storage.transformers[unit] then found = unit end
  end
  if head > n then
    storage.line_loss_dirty_list = {}
    head = 1
  end
  storage.line_loss_dirty_head = head
  return found
end

-- A search from a transformer: "out" over its downstream network from its
-- output pole, or "gen" over its upstream generator network from its input
-- pole. Both settle poles the same way (step_job); they differ in what they
-- record per pole and how they finish.
---@param unit UnitNumber
---@param kind "out"|"gen"
---@return table?
local function new_job(unit, kind)
  local parts = storage.transformers[unit]
  local start = parts and (kind == "gen" and parts.pole_in or parts.pole_out)
  if not (start and start.valid) then return nil end
  local job = {
    kind = kind,
    transformer = unit,
    urgent = true,  -- (saves before 0.1.5 also had background searches)
    start = start.unit_number,
    heap = {},
    dist = {[start.unit_number] = 0},
    done = {},
    -- Settled poles and their distances (pole ownership)
    settled = {},
  }
  if kind == "gen" then
    job.seen_generators = {}
    job.gens = {}  -- generator unit -> {distance, rated output}
    job.prev, job.order = {}, {}
  else
    job.prev, job.order = {}, {}
    job.count = 0
    job.sinks = {}
    if storage.settings.machine_weighting then
      job.machine_names = line_loss_consumer_names(start)
      job.seen_machines = {}
    end
  end
  heap_push(job.heap, {0, start.unit_number, start})
  return job
end

-- Generator networks -----------------------------------------------------------
-- A transformer whose upstream network is fed by no other transformer draws
-- straight from generators. Its upstream line loss comes from a second
-- search, from its input pole outwards over that network, with each pole
-- weighted by the rated output of the generators in its supply area: a steam
-- engine far down the line costs more than one next to the transformer. The
-- loss is drawn by a "Line loss" consumer on the generator network.

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
---@return number  rated output (W)
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
      v = result * 60   -- joules per tick -> watts
      break
    end
  end
  rated_cache[key] = v
  return v
end

-- Supply area distance of a pole, cached per prototype and quality
local supply_cache = {}
---@param pole LuaEntity
---@param name string?  the pole's prototype name, when the caller has it
local function supply_distance(pole, name)
  local quality = pole.quality
  local key = (name or pole.name) .. "/" .. (quality and quality.name or "normal")
  local v = supply_cache[key]
  if v then return v end
  local prototype = pole.prototype
  local ok
  ok, v = pcall(function() return prototype.get_supply_area_distance(quality) end)
  if not (ok and type(v) == "number") then
    ok, v = pcall(function() return prototype.supply_area_distance end)
    if not (ok and type(v) == "number") then v = 2.5 end
  end
  supply_cache[key] = v
  return v
end

-- Wire graph -------------------------------------------------------------------
-- storage.wire_graph[pole unit] = {e = pole, n = name, h = hidden, reach =
-- supply area distance, adj = {unit, entity, cost, ...} (pole neighbours, wire
-- cost = length x mean resistance), ids = unit numbers of every wire owner, in
-- the game's order}. Built the first time a search meets the pole, so a
-- search reads one value per pole (valid) instead of its wires. Kept in step
-- by the build/removal events (a pole and its neighbours are dropped) and by
-- the sweep. The sweep compares each pole's number of wires with the game (a
-- wire added or removed changes it at both ends); a slower second pass
-- compares every wire's far end, for swaps that keep the counts.

---@param pole LuaEntity
local function build_node(pole)
  local name = pole.name
  local info = info_of(name)
  local adj, ids = {}, {}
  local node = {e = pole, n = name, h = info.hidden, reach = info.hidden and 0 or supply_distance(pole, name), adj = adj, ids = ids}
  local connector = pole.get_wire_connector(defines.wire_connector_id.pole_copper, false)
  if connector then
    local r1 = info.r
    local p1 = pole.position
    for _, connection in pairs(connector.connections) do
      local other = connection.target.owner
      local other_unit = other.unit_number
      ids[#ids + 1] = other_unit or 0
      local other_info = info_of(other.name)
      if other_info.pole and other_unit then
        local p2 = other.position
        local dx, dy = p2.x - p1.x, p2.y - p1.y
        local n = #adj
        adj[n + 1] = other_unit
        adj[n + 2] = other
        local cost = math.sqrt(dx * dx + dy * dy) * 0.5 * (r1 + other_info.r)
        if line_loss_mixed_wire(name, other.name) then cost = cost * (storage.settings.mixed or 1) end
        adj[n + 3] = cost
      end
    end
  end
  return node
end

---@param pole LuaEntity  valid
---@param unit_number UnitNumber
local function node_of(pole, unit_number)
  local graph = storage.wire_graph
  local node = graph[unit_number]
  if not node then
    node = build_node(pole)
    graph[unit_number] = node
    storage.wire_graph_rev = (storage.wire_graph_rev or 0) + 1
  end
  return node
end

-- LuaWireConnector.connection_count, when this game version has it
local has_connection_count
local function connection_count(connector)
  if has_connection_count == nil then
    has_connection_count = pcall(function() return connector.connection_count end)
  end
  if has_connection_count then return connector.connection_count end
  return #connector.connections
end

-- Does the cached wire list still match the game? Quick: the number of wires
local function node_matches(node, pole, full)
  local connector = pole.get_wire_connector(defines.wire_connector_id.pole_copper, false)
  local ids = node.ids
  if not connector then return #ids == 0 end
  if not full then return connection_count(connector) == #ids end
  local connections = connector.connections
  if #connections ~= #ids then return false end
  for x = 1, #connections do
    if (connections[x].target.owner.unit_number or 0) ~= ids[x] then return false end
  end
  return true
end

-- A pole was built or is about to be removed: drop it and its neighbours
---@param pole LuaEntity
function wire_graph_pole_changed(pole)
  local graph = storage.wire_graph
  if not graph then return end
  local unit_number = pole.unit_number
  if unit_number then graph[unit_number] = nil end
  storage.wire_graph_rev = (storage.wire_graph_rev or 0) + 1
  local connector = pole.get_wire_connector(defines.wire_connector_id.pole_copper, false)
  if connector then
    for _, connection in pairs(connector.connections) do
      local other_unit = connection.target.owner.unit_number
      if other_unit then graph[other_unit] = nil end
    end
  end
end

-- Drops the cached neighbours in a wire list, so they are rebuilt too
local function drop_neighbours(graph, adj)
  for x = 1, #adj, 3 do graph[adj[x]] = nil end
  storage.wire_graph_rev = (storage.wire_graph_rev or 0) + 1
end

-- Checks up to `budget` cached poles against the game; a pole whose wires
-- changed is rebuilt, its old and new neighbours dropped, and its network
-- searched again
local function sweep_wire_graph(budget)
  local graph = storage.wire_graph
  local list, pos = storage.wire_sweep_list, storage.wire_sweep_pos or 1
  if not list or pos > #list then
    list = {}
    for unit_number in pairs(graph) do list[#list + 1] = unit_number end
    table.sort(list)
    storage.wire_sweep_list, pos = list, 1
  end
  local n = #list
  -- Full checks walk the same list with their own cursor
  local full_pos = storage.wire_full_pos or 1
  local full_budget = SWEEP_FULL_PER_TICK
  while (budget > 0 and pos <= n) or (full_budget > 0 and n > 0) do
    local full = false
    local unit_number
    if full_budget > 0 and n > 0 then
      if full_pos > n then full_pos = 1 end
      unit_number = list[full_pos]
      full_pos = full_pos + 1
      full_budget = full_budget - 1
      full = true
    else
      unit_number = list[pos]
      pos = pos + 1
    end
    local node = graph[unit_number]
    if node then
      if not full then budget = budget - 1 end
      local pole = node.e
      if not pole.valid then
        -- Gone without an event
        graph[unit_number] = nil
        drop_neighbours(graph, node.adj)
      elseif not node_matches(node, pole, full) then
        local new = build_node(pole)
        drop_neighbours(graph, node.adj)
        drop_neighbours(graph, new.adj)
        graph[unit_number] = new
        mark_line_loss_network(pole.electric_network_id)
      end
    end
  end
  storage.wire_sweep_pos = pos
  storage.wire_full_pos = full_pos
end

-- Rated output of the generators in a pole's supply area, each generator
-- counted once per search (for the nearest pole reaching it)
---@param pole LuaEntity
---@param job table  records each generator's distance and rating in job.gens
---@param d number   the pole's distance
---@param r number   the pole's supply area distance
local function generator_weight(pole, job, d, r)
  local seen = job.seen_generators
  if r <= 0 then return 0 end
  local p = pole.position  -- poles without a supply area (big, huge, fuses)
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
---@param r number  the pole's supply area distance
---@return table?  machine name -> count
local function machine_counts(pole, job, r)
  local names = job.machine_names
  if not names then return nil end
  if r <= 0 then return nil end
  local p = pole.position
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

-- name -> count from a per-type summary
function type_totals(types)
  local totals = {}
  for name, x in pairs(types) do totals[name] = x.n end
  return totals
end

local function add_types(types, counts)
  if not counts then return end
  for name, c in pairs(counts) do
    local x = types[name]
    if not x then
      x = {n = 0}
      types[name] = x
    end
    x.n = x.n + c
  end
end


local function finish_generator_job(job)
  local parts = storage.transformers[job.transformer]
  if not parts then return end
  local total_w = 0
  for _, item in ipairs(job.settled) do total_w = total_w + item[3] end
  local num_d, den, weights = 0, 0, {}
  for _, item in ipairs(job.settled) do
    -- No generators found next to any pole: spread generation evenly
    local w = total_w > 0 and item[3] or 1
    num_d, den = num_d + w * item[2], den + w
    if w > 0 and item[4] then weights[item[4]] = w end
  end
  parts.gen_fed = true
  parts.gen_distance = den > 0 and num_d / den or 0
  local count = 0
  for _ in pairs(job.gens) do count = count + 1 end
  parts.gen_count = count  -- generators found on its upstream network (panel)
  set_generator_consumer(parts, true)
  -- Search tree and generator weight per pole (kirchhoff.lua, feeder highlight)
  parts.gen_tree = {start = job.start, prev = job.prev, order = job.order, weights = weights, dist = job.dist,
    total = total_w > 0 and total_w or #job.settled, no_generators = total_w <= 0}
end

-- Not (or no longer) on a generator network
---@param unit UnitNumber
local function clear_generator_loss(unit)
  local parts = storage.transformers[unit]
  if parts and parts.gen_fed then
    parts.gen_fed, parts.gen_distance, parts.gen_count, parts.gen_tree = nil, nil, nil, nil
    set_generator_consumer(parts, false)
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
    transformer_parts.line_sinks = job.sinks
    transformer_parts.line_n = job.count  -- poles with a supply area
    -- Machines per type over the whole network (machine weighting)
    local types, any = {}, false
    for _, item in ipairs(job.settled) do
      if item[3] then
        add_types(types, item[3])
        any = true
      end
    end
    transformer_parts.line_types = any and types or nil
    -- Shortest-path tree (line loading views, feeder highlight)
    transformer_parts.line_tree = {start = job.start, dist = job.dist, prev = job.prev, order = job.order}
    pole_ownership_apply(job.transformer, job.settled)
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
      local node = node_of(pole, unit_number)
      local name = node.n
      local hidden = node.h
      local order = job.order
      if order then order[#order + 1] = unit_number end
      if job.kind == "gen" then
        if not hidden then
          job.settled[#job.settled + 1] = {pole, d, generator_weight(pole, job, d, node.reach), unit_number}
        end
      elseif not hidden then
        -- Machines are spread only over poles that can power them: big poles,
        -- huge poles and fuses have no supply area, so they only carry power
        local reach = node.reach
        local supplies = reach > 0
        if supplies then job.count = job.count + 1 end
        local settled = job.settled
        if settled then settled[#settled + 1] = {pole, d, supplies and machine_counts(pole, job, reach) or nil, not supplies} end
      elseif name == HIDDEN_INPUT_POLE then
        -- Another transformer's input: a consumer on this network
        local sink = get_input_poles()[unit_number]
        if sink and sink ~= job.transformer then
          job.sinks[#job.sinks + 1] = {unit = sink, d = d}
        end
      end
      -- Hidden poles (other transformers' inputs, alt-surface poles) are
      -- endpoints: the network does not continue through them.
      if unit_number == job.start or not hidden then
        local adj = node.adj
        for x = 1, #adj, 3 do
          local other_unit_number = adj[x]
          if not done[other_unit_number] then
            local new_d = d + adj[x + 2]
            local best = dist[other_unit_number]
            if not best or new_d < best then
              dist[other_unit_number] = new_d
              if job.prev then job.prev[other_unit_number] = unit_number end
              heap_push(heap, {new_d, other_unit_number, adj[x + 1]})
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
  if not storage.wire_graph then storage.wire_graph = {} end
  resolve_pending_networks()

  local job = storage.line_loss_job
  if job and not job.urgent then
    -- A background search from before 0.1.5: start over from the queue
    job = nil
    storage.line_loss_job = nil
  end
  if not job and #storage.line_loss_dirty_list == 0 then
    sweep_wire_graph(SWEEP_POLES_PER_TICK)
    return
  end
  local budget = POLES_PER_TICK
  -- Bounded so that a run of transformers with tiny networks cannot spin
  local starts = 0
  while budget > 0 and starts < 10 do
    if not job then
      local unit = pop_dirty()
      if not unit then return end
      job = new_job(unit, "out")
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
        -- generators also searches its upstream network
        if finished.kind == "out" then
          local parts = storage.transformers[finished.transformer]
          if parts and on_generator_network(parts) then
            job = new_job(finished.transformer, "gen")
            storage.line_loss_job = job
          else
            clear_generator_loss(finished.transformer)
          end
        end
      end
    end
  end
end

-- Pole ownership ---------------------------------------------------------------
-- Each pole belongs to the transformer electrically closest to it (shortest
-- resistance-weighted distance; ties go to the lower unit number): that
-- transformer's network load spreads over it (machine-loads.lua).

local function owner_of(entry)
  local best, best_d
  for source, d in pairs(entry.s) do
    if not best_d or d < best_d or (d == best_d and source < best) then
      best, best_d = source, d
    end
  end
  return best
end

-- Updates pole ownership after a search
---@param source UnitNumber
---@param settled table  {{pole, distance, machine counts, no supply area}, ...}
function pole_ownership_apply(source, settled)
  local pole_dist = storage.pole_dist
  local reach = storage.source_reach
  if not (pole_dist and reach) then return end
  local old = reach[source] or {}
  local new = {}
  for _, item in ipairs(settled) do
    local pole = item[1]
    if pole.valid then
      local unit = pole.unit_number
      new[unit] = true
      local entry = pole_dist[unit]
      if not entry then
        entry = {s = {}}
        pole_dist[unit] = entry
      end
      entry.m = item[3]
      entry.ns = item[4] or nil  -- no supply area: carries power, powers no machine
      entry.s[source] = item[2]
      entry.owner = owner_of(entry)
    end
  end
  for unit in pairs(old) do
    local entry = not new[unit] and pole_dist[unit]
    if entry then
      entry.s[source] = nil
      entry.owner = owner_of(entry)
      if not entry.owner then pole_dist[unit] = nil end
    end
  end
  reach[source] = new
end

-- A source transformer was removed: its poles go to the next nearest source
---@param source UnitNumber
function pole_ownership_forget_source(source)
  local pole_dist = storage.pole_dist
  local reach = storage.source_reach
  if not (pole_dist and reach and reach[source]) then return end
  for unit in pairs(reach[source]) do
    local entry = pole_dist[unit]
    if entry then
      entry.s[source] = nil
      entry.owner = owner_of(entry)
      if not entry.owner then pole_dist[unit] = nil end
    end
  end
  reach[source] = nil
end

-- True when at least one transformer in a feeders table still exists. A
-- feeder removed before its own search could tidy up would otherwise hide a
-- transformer's generator line loss.
local function has_live_feeder(feeders)
  if not feeders then return false end
  local transformers = storage.transformers
  for source in pairs(feeders) do
    if transformers[source] then return true end
  end
  return false
end

-- Total upstream loss: of the power generated for a transformer, the share
-- lost before it reaches the transformer's input, over every segment (the
-- wires between two transformers, or between the generators and a
-- transformer) and every transformer on the way, its own losses excluded.
-- Split by kind: line loss, inefficiency, core loss. Each feeder counts for
-- its share of the power arriving (kirchhoff.lua). Memoised per tick; derived
-- from storage only, so every client computes the same values.
local cumulative_cache, cumulative_cache_tick = {}, -1

-- Share of a transformer's draw that it passes on (its output), and how its
-- own loss splits between inefficiency and core loss. An idle transformer
-- passes on the efficiency setting, with no core loss counted.
local function transfer(parts)
  local draw, out = parts.p_draw or 0, parts.p_out or 0
  local ineff, core = parts.ineff_burn or 0, parts.no_load_burn or 0
  if draw > 0 and out > 0 and out <= draw then
    local lost = draw - out
    local split = ineff + core > 0 and ineff / (ineff + core) or 1
    return out / draw, lost / draw * split, lost / draw * (1 - split)
  end
  local e = storage.settings.efficiency or 1
  return e, 1 - e, 0
end

-- The transformers feeding one: {source, sent (W), share, d} for each whose
-- share of the power arriving is at least 0.1% (shares from the flows; equal
-- shares until the first solve). d: resistance-weighted shortest distance.
-- nil when it is not fed by transformers.
---@param unit_number UnitNumber
---@return table?
function get_assigned_feeders(unit_number)
  local feeders = storage.line_loss_feeders and storage.line_loss_feeders[unit_number]
  if not has_live_feeder(feeders) then return nil end
  local transformers = storage.transformers
  local parts = transformers[unit_number]
  local k = parts and kirchhoff_values(parts)
  local shares = k and k.kirch_shares
  if shares and next(shares) == nil then shares = nil end  -- idle input: equal shares
  local list, total = {}, 0
  for source, d in pairs(feeders) do
    if transformers[source] then
      local share = shares and (shares[source] or 0) or 1
      if not shares or share > 0.001 then
        list[#list + 1] = {source = source, d = d, share = share}
        total = total + share
      end
    end
  end
  if #list == 0 then return nil end
  local draw = parts and parts.p_draw or 0
  for _, f in ipairs(list) do
    f.share = f.share / total
    f.sent = draw * f.share
  end
  table.sort(list, function(a, b) return a.source < b.source end)
  return list
end

-- Line loss on the last segment, from the flows; nil until the first solve
---@param parts table
---@return number?
local function segment_loss(parts)
  local k = kirchhoff_values(parts)
  return k and (k.kirch_up_loss or k.kirch_gen_loss)
end

-- {surviving, line, ineff, core} at a transformer's input, as shares of the
-- power generated for it (they add up to 1). `path` stops loops.
---@return number, number, number, number
local function upstream_shares(unit, path, depth)
  local parts = storage.transformers[unit]
  if path[unit] or depth > 32 or not parts then return 1, 0, 0, 0 end
  local loss = segment_loss(parts) or 0
  local feeders = get_assigned_feeders(unit)
  if not feeders then
    -- Fed straight by generators: one segment, line loss only
    return 1 - loss, loss, 0, 0
  end
  path[unit] = true
  local t = {0, 0, 0, 0}
  for _, f in ipairs(feeders) do
    local surv, line, ineff, core = upstream_shares(f.source, path, depth + 1)
    -- the feeder itself
    local e, e_ineff, e_core = transfer(storage.transformers[f.source])
    ineff, core, surv = ineff + surv * e_ineff, core + surv * e_core, surv * e
    -- the segment from the feeder to here
    line, surv = line + surv * loss, surv * (1 - loss)
    local w = f.share
    t[1], t[2], t[3], t[4] = t[1] + w * surv, t[2] + w * line, t[3] + w * ineff, t[4] + w * core
  end
  path[unit] = nil
  if not (t[1] == t[1] and t[1] >= 0 and t[1] <= 1) then return 1, 0, 0, 0 end
  return t[1], t[2], t[3], t[4]
end

---@param unit_number UnitNumber
---@return number? total, number? line, number? inefficiency, number? core
---  shares of the power generated for this transformer, lost before its
---  input; nil when line losses are off or the transformer is unknown
function get_cumulative_upstream_loss(unit_number)
  if not storage.settings.enabled then return nil end
  if not storage.transformers[unit_number] then return nil end
  local tick = game.tick
  if cumulative_cache_tick ~= tick then
    cumulative_cache, cumulative_cache_tick = {}, tick
  end
  local entry = cumulative_cache[unit_number]
  if not entry then
    local surv, line, ineff, core = upstream_shares(unit_number, {}, 0)
    entry = {1 - surv, line, ineff, core}
    cumulative_cache[unit_number] = entry
  end
  return entry[1], entry[2], entry[3], entry[4]
end

-- Upstream loss of a transformer fed straight by generators (drawn by its
-- input "Line loss" consumer), and the rated-output-weighted distance to them
---@param parts table
---@return number? loss, number? distance
function get_generator_loss(parts)
  if not parts.gen_fed then return nil end
  local k = kirchhoff_values(parts)
  return k and k.kirch_gen_loss or 0, parts.gen_distance
end

-- Line loss of the last segment (display only: charged to the transformers
-- feeding the network, or here for a generator network), and the
-- share-weighted distance to the feeders
---@param unit_number UnitNumber
---@return number? loss, number? distance  nil when not known yet
function get_upstream_line_loss(unit_number)
  if not storage.settings.enabled then return nil end
  local parts = storage.transformers[unit_number]
  if not parts then return nil end
  local feeders = get_assigned_feeders(unit_number)
  if not feeders then return get_generator_loss(parts) end
  local loss = segment_loss(parts)
  if not loss then return nil end
  local distance = 0
  for _, f in ipairs(feeders) do distance = distance + f.share * f.d end
  return loss, distance
end

-- What powers a transformer, for the panel: its feeders, or the generators
-- on its upstream network; and the distance to them.
---@param unit_number UnitNumber
---@return "transformers"|"generators"|nil kind, integer count, number? distance
function get_feeder_summary(unit_number)
  local parts = storage.transformers[unit_number]
  if not parts then return nil, 0 end
  local assigned = get_assigned_feeders(unit_number)
  if assigned then
    local _, distance = get_upstream_line_loss(unit_number)
    return "transformers", #assigned, distance
  end
  if parts.gen_fed then
    return "generators", parts.gen_count or 0, parts.gen_distance
  end
  return nil, 0
end

-- Fraction of energy that survives the line, for a transformer
---@param transformer_parts TransformerData
---@return number
function get_line_factor(transformer_parts)
  if not storage.settings.enabled then return 1 end
  local k = kirchhoff_values(transformer_parts)
  local loss = k and k.kirch_line_loss or 0
  -- NaN fails every comparison, so test for it explicitly
  if loss ~= loss or loss < 0 then return 1 end
  if loss > LINE_LOSS_MAX then loss = LINE_LOSS_MAX end
  return 1 - loss
end

-- (control.lua: generators built or removed queue their network)
line_loss_search = {
  is_generator = function(entity)
    local entity_type = entity.type
    for _, t in pairs(generator_types(entity.surface)) do
      if t == entity_type then return true end
    end
    return false
  end,
  -- Generators in a pole's supply area (kirchhoff.lua: generator sources)
  generators_near = function(pole, r)
    if r <= 0 then return {} end
    local p = pole.position
    return pole.surface.find_entities_filtered{
      area = {{p.x - r, p.y - r}, {p.x + r, p.y + r}},
      type = generator_types(pole.surface),
    }
  end,
  rated_output = function(entity) return rated_output(entity) end,
}
