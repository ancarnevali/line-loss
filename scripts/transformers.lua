-- Tracks Power Overload's transformers, measures the power each one moves,
-- and charges the losses through hidden consumers next to each transformer:
--   "Line loss"      on the downstream network: delivered * L / (1 - L),
--                    L = downstream line loss
--   "Transf. ineff." on the upstream network: inefficiency
--                    p_in * (1 - e) / e, plus the core loss (a share of the
--                    rating, while switched on)
--   "Line loss"      on the upstream network, when it is fed straight by
--                    generators: drawn * L / (1 - L), L = generator line loss
--
-- Power Overload keeps its transformer data private, so this mod finds the
-- transformer's hidden parts itself:
--   * hidden input / output poles on the transformer's surface, 0.6 tiles
--     left / right of the transformer;
--   * hidden interfaces on the "<surface>-transformer" surface at the same
--     positions, joined to those networks.
-- Our consumers go on that hidden surface too, at the same positions, so they
-- join the same networks without being visible or in the way.
--
-- Power per transformer: every MEASURE_INTERVAL ticks, the downstream network's
-- statistics give how much Power Overload's output interfaces produced. When
-- several transformers feed the same network, that total is split by their
-- buffer sizes, which Power Overload adapts to each transformer's throughput.

---@class LineLossTransformer
---@field transformer LuaEntity
---@field unit UnitNumber
---@field force LuaForce
---@field position_in MapPosition
---@field position_out MapPosition
---@field pole_in LuaEntity?   Power Overload's hidden input pole
---@field pole_out LuaEntity?  Power Overload's hidden output pole
---@field interface_out LuaEntity?  Power Overload's hidden output interface
---@field line_eei LuaEntity?   "Line loss" consumer (downstream network)
---@field ineff_eei LuaEntity?  "Transf. ineff." consumer (upstream network)
---@field line_in_eei LuaEntity?  "Line loss" consumer on the upstream network, when it is a generator network
---@field gen_loss number?  upstream line loss from generators (generator networks only)
---@field gen_burn number   power burned by line_in_eei (W)
---@field p_out number   power given to the downstream network, including the line loss (W)
---@field p_deliv number power that reaches consumers after the line loss (W)
---@field p_in number    power Power Overload's input interface takes (W)
---@field p_draw number  total power drawn from the upstream network: p_in + inefficiency + core loss (W)
---@field line_burn number
---@field ineff_burn number
---@field line_distance number?  load-weighted distance (line-losses.lua)
---@field rating number?  rated power: the weaker side's strongest pole (W)
---@field no_load_burn number  constant loss while switched on (W)

TRANSFORMER_NAMES = {
  ["po-transformer"] = true,
  ["po-transformer-high"] = true,
  ["po-transformer-low"] = true,
}
TRANSFORMER_NAME_LIST = {"po-transformer", "po-transformer-high", "po-transformer-low"}

LINE_EEI = "line-loss-line-consumer"
INEFF_EEI = "line-loss-ineff-consumer"
PO_INPUT_INTERFACE = "po-transformer-interface-hidden-in"
local OUTPUT_INTERFACES = {
  "po-transformer-interface-hidden-out",
  "po-transformer-interface-hidden-out-high",
  "po-transformer-interface-hidden-out-low",
}
local HIDDEN_POLE_IN = "po-hidden-electric-pole-in"
local HIDDEN_POLE_OUT = "po-hidden-electric-pole-out"

MEASURE_INTERVAL = 60

-- Rated power ---------------------------------------------------------------------
-- A transformer is rated by the weaker of its two sides: on each side, the
-- highest-rated pole wired to its hidden pole (quality included); the rating
-- is the smaller of the two. It can never usefully carry more, since the
-- weaker side's poles would overload first.

local rating_lookup
---@param pole LuaEntity
---@return number?
local function pole_rating(pole)
  if not rating_lookup then
    rating_lookup = ratings.make_rating_lookup(shared, settings.startup, script.active_mods)
  end
  local w = rating_lookup(pole.name)
  if not w then return nil end
  local quality = pole.quality
  return w * (quality and quality.default_multiplier or 1)
end

---@param hidden_pole LuaEntity?
---@return number?, string?  highest rating among the real poles wired to it, and that pole's name
local function side_rating(hidden_pole)
  if not (hidden_pole and hidden_pole.valid) then return nil end
  local connector = hidden_pole.get_wire_connector(defines.wire_connector_id.pole_copper, false)
  if not connector then return nil end
  local best, best_name
  for _, connection in pairs(connector.connections) do
    local other = connection.target.owner
    if other.valid and other.type == "electric-pole" and string.sub(other.name, 1, 10) ~= "po-hidden-" then
      local w = pole_rating(other)
      if w and (not best or w > best) then best, best_name = w, other.name end
    end
  end
  return best, best_name
end

---@param parts LineLossTransformer
local function update_rating(parts)
  local r_in, name_in = side_rating(parts.pole_in)
  local r_out, name_out = side_rating(parts.pole_out)
  -- for the panel's core-loss tooltip
  parts.rating_in = r_in and {w = r_in, name = name_in} or nil
  parts.rating_out = r_out and {w = r_out, name = name_out} or nil
  if r_in and r_out then
    parts.rating = math.min(r_in, r_out)
  else
    parts.rating = r_in or r_out  -- one side not wired yet
  end
end
local SMOOTHING = 0.4      -- weight of the newest sample in the running average
local REFRESH_INTERVAL = 600  -- re-find Power Overload's hidden parts this often

-- Network loads ----------------------------------------------------------------

local quality_names
local function get_quality_names()
  if not quality_names then
    quality_names = {}
    for name in pairs(prototypes.quality) do quality_names[name] = true end
  end
  return quality_names
end

---@param statistics LuaFlowStatistics
---@param category "input"|"output"
---@param name string
---@param quality string
local function flow(statistics, category, name, quality)
  return 60 * statistics.get_flow_count{
    name = {name = name, quality = quality},
    category = category,
    precision_index = defines.flow_precision_index.five_seconds,
    sample_index = 1,
    count = false,
  }
end

-- Splits a network's consumption into machines, our two loss consumers and
-- Power Overload's transformer inputs. Same sampling as Power Overload's own
-- pole readout. Cached per network for a short while.
---@class NetworkLoads
---@field machines number  everything else: machines, accumulators charging, ...
---@field line number
---@field ineff number
---@field transformers number

local LOADS_TTL = 20
-- network id -> {tick, loads}. Kept in storage: a reading is reused for
-- LOADS_TTL ticks, so a player joining a multiplayer game must receive the
-- same readings the others hold instead of taking fresh ones.
local function loads_cache_table()
  local cache = storage.loads_cache
  if not cache then
    cache = {}
    storage.loads_cache = cache
  end
  return cache
end

---@param pole LuaEntity
---@param tick GameTick
---@return NetworkLoads
function get_network_loads(pole, tick)
  local network_id = pole.electric_network_id
  if not network_id then return {machines = 0, line = 0, ineff = 0, transformers = 0, by_name = {}} end
  local loads_cache = loads_cache_table()
  local entry = loads_cache[network_id]
  if entry and tick - entry.tick < LOADS_TTL and tick >= entry.tick then return entry.loads end

  local loads = {machines = 0, line = 0, ineff = 0, transformers = 0, by_name = {}}
  local statistics = pole.electric_network_statistics
  local qualities = get_quality_names()
  local function add(name, quality)
    local value = flow(statistics, "input", name, quality)
    if name == LINE_EEI then
      loads.line = loads.line + value
    elseif name == INEFF_EEI then
      loads.ineff = loads.ineff + value
    elseif name == PO_INPUT_INTERFACE then
      loads.transformers = loads.transformers + value
    else
      loads.machines = loads.machines + value
      loads.by_name[name] = (loads.by_name[name] or 0) + value
    end
  end
  -- input_quality_counts lists only the (quality, prototype) pairs that exist.
  -- Its orientation is detected rather than assumed, as Power Overload does.
  for outer, inner in pairs(statistics.input_quality_counts or {}) do
    if type(inner) == "table" then
      if qualities[outer] then
        for name in pairs(inner) do add(name, outer) end
      else
        for quality in pairs(inner) do
          if qualities[quality] then add(outer, quality) end
        end
      end
    end
  end
  loads_cache[network_id] = {tick = tick, loads = loads}
  return loads
end

function purge_loads_cache(tick)
  local loads_cache = loads_cache_table()
  for network_id, entry in pairs(loads_cache) do
    if tick - entry.tick > 600 or tick < entry.tick then loads_cache[network_id] = nil end
  end
end

-- Tracking ----------------------------------------------------------------------

---@param entity LuaEntity
function register_transformer(entity)
  if not (entity and entity.valid and TRANSFORMER_NAMES[entity.name]) then return end
  local unit = entity.unit_number
  if storage.transformers[unit] then return end
  local position = entity.position
  storage.transformers[unit] = {
    transformer = entity,
    unit = unit,
    force = entity.force,
    position_in = {x = position.x - 0.6, y = position.y},
    position_out = {x = position.x + 0.6, y = position.y},
    p_out = 0, p_deliv = 0, p_in = 0, p_draw = 0, line_burn = 0, ineff_burn = 0,
  }
  script.register_on_object_destroyed(entity)
end

---@param unit UnitNumber
function unregister_transformer(unit)
  local parts = storage.transformers[unit]
  if not parts then return end
  for _, key in pairs({"line_eei", "ineff_eei", "line_in_eei"}) do
    local entity = parts[key]
    if entity and entity.valid then entity.destroy() end
  end
  storage.transformers[unit] = nil
  local feeders = storage.line_loss_feeders
  if feeders then
    -- No longer a consumer, and no longer a feeder of anything
    feeders[unit] = nil
    for _, f in pairs(feeders) do f[unit] = nil end
  end
  -- The transformers that fed it lose a consumer
  invalidate_line_loss_inputs()
  mark_line_loss_network(parts.in_net)
  pole_ownership_forget_source(unit)
  generator_ownership_forget(unit)
  heatmap_forget_source(unit)
end

function scan_transformers()
  storage.transformers = storage.transformers or {}
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{name = TRANSFORMER_NAME_LIST}) do
      register_transformer(entity)
    end
  end
  -- Consumers left without a transformer (e.g. after a failed removal)
  local known = {}
  for _, parts in pairs(storage.transformers) do
    if parts.line_eei and parts.line_eei.valid then known[parts.line_eei.unit_number or 0] = true end
    if parts.ineff_eei and parts.ineff_eei.valid then known[parts.ineff_eei.unit_number or 0] = true end
    if parts.line_in_eei and parts.line_in_eei.valid then known[parts.line_in_eei.unit_number or 0] = true end
  end
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{name = {LINE_EEI, INEFF_EEI}}) do
      if not known[entity.unit_number or 0] then entity.destroy() end
    end
  end
end

---@param surface LuaSurface
---@param name string|string[]
---@param position MapPosition
local function find_at(surface, name, position)
  return surface.find_entities_filtered{name = name, position = position, radius = 0.1, limit = 1}[1]
end

---@param parts LineLossTransformer
---@param key string
---@param name string
---@param surface LuaSurface
---@param position MapPosition
local function ensure_consumer(parts, key, name, surface, position)
  local entity = parts[key]
  if entity and entity.valid then return entity end
  entity = find_at(surface, name, position)  -- e.g. left over from an earlier save
  if not entity then
    entity = surface.create_entity{name = name, position = position, force = parts.force}
  end
  if entity then
    entity.power_usage = 0
    entity.electric_buffer_size = 1000
  end
  parts[key] = entity
  return entity
end

-- "Line loss" consumer on the upstream network, kept only while that is a
-- generator network (the transformer pays for the wires to its generators)
---@param parts LineLossTransformer
---@param wanted boolean
function set_generator_consumer(parts, wanted)
  if wanted then
    local entity = parts.transformer
    if not (entity and entity.valid) then return end
    local hidden_surface = game.get_surface(entity.surface.name .. "-transformer")
    if hidden_surface then ensure_consumer(parts, "line_in_eei", LINE_EEI, hidden_surface, parts.position_in) end
  elseif parts.line_in_eei then
    if parts.line_in_eei.valid then parts.line_in_eei.destroy() end
    parts.line_in_eei = nil
  end
end

-- Finds Power Overload's hidden parts and creates our consumers next to them.
-- Power Overload creates its interfaces a tick after the transformer is built
-- and may recreate them, so this is retried until everything is found.
---@param parts LineLossTransformer
local function refresh_parts(parts)
  local entity = parts.transformer
  local surface = entity.surface
  if not (parts.pole_in and parts.pole_in.valid) then
    parts.pole_in = find_at(surface, HIDDEN_POLE_IN, parts.position_in)
    if parts.pole_in then
      -- New consumer on its upstream network: the transformers feeding it
      invalidate_line_loss_inputs()
      mark_line_loss_network(parts.pole_in.electric_network_id)
    end
  end
  if not (parts.pole_out and parts.pole_out.valid) then
    parts.pole_out = find_at(surface, HIDDEN_POLE_OUT, parts.position_out)
    if parts.pole_out then
      mark_line_loss_dirty(parts.unit)
      -- Transformers drawing from that network may no longer be on a
      -- generator network
      mark_line_loss_network(parts.pole_out.electric_network_id)
    end
  end
  local hidden_surface = game.get_surface(surface.name .. "-transformer")
  if not hidden_surface then return end
  if not (parts.interface_out and parts.interface_out.valid) then
    parts.interface_out = find_at(hidden_surface, OUTPUT_INTERFACES, parts.position_out)
  end
  ensure_consumer(parts, "line_eei", LINE_EEI, hidden_surface, parts.position_out)
  ensure_consumer(parts, "ineff_eei", INEFF_EEI, hidden_surface, parts.position_in)
  set_generator_consumer(parts, parts.gen_loss_all ~= nil)
end

local function complete(parts)
  return parts.pole_in and parts.pole_in.valid and parts.pole_out and parts.pole_out.valid
    and parts.interface_out and parts.interface_out.valid
    and parts.line_eei and parts.line_eei.valid and parts.ineff_eei and parts.ineff_eei.valid
    and (parts.gen_loss_all == nil) == (parts.line_in_eei == nil)
end

---@param entity LuaEntity?
---@param watts number
local function set_burn(entity, watts)
  if not (entity and entity.valid) then return end
  if not (watts == watts and watts > 0 and watts < math.huge) then watts = 0 end
  local per_tick = watts / 60
  -- Room for a few ticks so the consumer is never limited by its own buffer
  local buffer = per_tick * 4
  if buffer < 1000 then buffer = 1000 end
  entity.electric_buffer_size = buffer
  entity.power_usage = per_tick
end

-- Efficiency settings -----------------------------------------------------------

---@return boolean active, number efficiency
local function ineff_settings()
  local s = storage.settings
  -- Only when Power Overload itself transfers losslessly, otherwise the
  -- inefficiency would be charged twice
  local active = s.po_efficiency >= 0.9999 and s.efficiency < 1
  return active, s.efficiency
end

function check_po_efficiency_warning()
  local po_efficiency = storage.settings.po_efficiency
  if po_efficiency >= 0.9999 then
    storage.po_efficiency_warned = nil
    return
  end
  if storage.po_efficiency_warned or #game.connected_players == 0 then return end
  game.print({"line-loss.po-efficiency-warning",
    string.format("%g", po_efficiency * 100),
    string.format("%g", storage.settings.efficiency * 100)})
  storage.po_efficiency_warned = true
end

-- Measurement and losses --------------------------------------------------------

---@param tick GameTick
function update_transformers(tick)
  if tick % MEASURE_INTERVAL ~= 0 then return end
  local transformers = storage.transformers
  local refresh = tick % REFRESH_INTERVAL == 0
  check_po_efficiency_warning()

  -- Group working transformers by downstream network and interface prototype
  local groups = {}  -- network id -> {pole, by_name = {name -> {total, list}}}
  for unit, parts in pairs(transformers) do
    local entity = parts.transformer
    if not (entity and entity.valid) then
      unregister_transformer(unit)
    else
      if refresh or not complete(parts) then refresh_parts(parts) end
      if refresh or parts.rating == nil then update_rating(parts) end
      parts.sampled = false
      -- A changed network id means its network merged or split: search again
      local pole_out, pole_in = parts.pole_out, parts.pole_in
      local out_net = pole_out and pole_out.valid and pole_out.electric_network_id or nil
      if out_net ~= parts.out_net then
        parts.out_net = out_net
        mark_line_loss_dirty(unit)
        update_rating(parts)  -- rewired
      end
      local in_net = pole_in and pole_in.valid and pole_in.electric_network_id or nil
      if in_net ~= parts.in_net then
        parts.in_net = in_net
        mark_line_loss_dirty(unit)  -- its upstream network changed
      end
      local interface = parts.interface_out
      if entity.power_switch_state and interface and interface.valid and pole_out and pole_out.valid then
        local network_id = pole_out.electric_network_id
        if network_id then
          local group = groups[network_id]
          if not group then
            group = {pole = pole_out, by_name = {}}
            groups[network_id] = group
          end
          local name = interface.name
          local list = group.by_name[name]
          if not list then
            list = {total = 0}
            group.by_name[name] = list
          end
          local buffer = interface.electric_buffer_size or 0
          list[#list + 1] = {parts = parts, buffer = buffer}
          list.total = list.total + buffer
        end
      end
    end
  end

  -- Each network's statistics, split by buffer size
  for _, group in pairs(groups) do
    local statistics = group.pole.electric_network_statistics
    for name, list in pairs(group.by_name) do
      local produced = flow(statistics, "output", name, "normal")
      for _, item in ipairs(list) do
        local share = list.total > 0 and item.buffer / list.total or 1 / #list
        local sample = produced * share
        if not (sample == sample and sample >= 0 and sample < math.huge) then sample = 0 end
        local parts = item.parts
        -- The sample includes what our line-loss consumer drew (the loss set
        -- last time), so smooth the useful part only: the loss is then
        -- recomputed from it exactly, instead of feeding back on itself
        -- (which would settle slowly at high losses)
        local useful = sample - parts.line_burn
        if useful < 0 then useful = 0 end
        parts.p_deliv = parts.p_deliv + SMOOTHING * (useful - parts.p_deliv)
        parts.sampled = true
      end
    end
  end

  local settings_ = storage.settings
  if settings_.no_load == nil then
    -- Saves from before this setting existed
    settings_.no_load = settings.global["line-loss-no-load"].value / 100
  end
  local ineff_active, efficiency = ineff_settings()
  local po_efficiency = settings_.po_efficiency > 0 and settings_.po_efficiency or 1
  for _, parts in pairs(transformers) do
    if not parts.sampled then
      -- Switched off or not complete yet: decay towards 0
      parts.p_deliv = parts.p_deliv * (1 - SMOOTHING)
      if parts.p_deliv < 1 then parts.p_deliv = 0 end
    end
    -- delivered = (1 - loss) * output, so line_burn = delivered * loss / (1 - loss)
    local loss = 1 - get_line_factor(parts)
    parts.line_burn = parts.p_deliv * loss / (1 - loss)
    parts.p_out = parts.p_deliv + parts.line_burn
    parts.p_in = parts.p_out / po_efficiency
    parts.ineff_burn = ineff_active and parts.p_in * (1 - efficiency) / efficiency or 0
    -- Core loss: constant while switched on, drawn with the inefficiency
    local entity = parts.transformer
    local on = entity and entity.valid and entity.power_switch_state
    parts.no_load_burn = on and (parts.rating or 0) * settings_.no_load or 0
    parts.p_draw = parts.p_in + parts.ineff_burn + parts.no_load_burn
    -- Fed straight by generators: the wires between them and this
    -- transformer lose gen_loss of what the generators send, so
    -- gen_burn = draw * loss / (1 - loss)
    local gen_loss = settings_.enabled and get_generator_loss(parts, tick) or 0
    if not (gen_loss == gen_loss and gen_loss > 0 and gen_loss < 1) then gen_loss = 0 end
    parts.gen_burn = parts.p_draw * gen_loss / (1 - gen_loss)
    set_burn(parts.line_eei, parts.line_burn)
    set_burn(parts.ineff_eei, parts.ineff_burn + parts.no_load_burn)
    set_burn(parts.line_in_eei, parts.gen_burn)
  end

  -- Load-weighted distances from the fresh power figures
  for _, parts in pairs(transformers) do
    update_line_distance(parts, tick)
  end

  if refresh then purge_loads_cache(tick) end
end
