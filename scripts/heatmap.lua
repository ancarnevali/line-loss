-- Line-loss map: one dot per pole on the map.
--   colour = line loss of the power reaching the pole from the nearest
--            transformer feeding its network (route loss of the shortest
--            resistance-weighted path), green to dark red;
--   size   = power lost delivering the machine load on that pole, from the
--            transformer that owns it (its electrically nearest source):
--            lost = load * L / (1 - L). Load per pole: with "weight machines
--            by their live load" on, the machines in its supply area times
--            what each machine type draws right now; otherwise the network's
--            machine load spread evenly over the poles with a supply area.
--            Below 1 kW (transmission poles, generator networks) the dot has
--            the smallest size.
-- A big red dot is far and heavily loaded: where an upgrade saves the most.
--
-- Map view only, per player, toggled with the "Toggle line-loss map"
-- shortcut (off by default). Data is kept only while someone has it on: the
-- searches hand over the poles they settle (line-losses.lua), and the sizes
-- are recomputed every UPDATE_INTERVAL ticks from pole ownership. Turning it
-- on re-runs every search, so the map fills in within a few seconds.

local SHORTCUT = "line-loss-toggle-heatmap"
local UPDATE_INTERVAL = 60

-- Colour steps by route loss (upper bounds), green to red
local STEPS = {0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, math.huge}
local COLOURS = {
  {r = 0.20, g = 0.90, b = 0.20},
  {r = 0.45, g = 0.90, b = 0.15},
  {r = 0.70, g = 0.90, b = 0.10},
  {r = 1.00, g = 0.85, b = 0.10},
  {r = 1.00, g = 0.60, b = 0.10},
  {r = 1.00, g = 0.40, b = 0.15},
  {r = 1.00, g = 0.20, b = 0.20},
  {r = 0.70, g = 0.00, b = 0.20},
}

local function step_for(loss)
  for i, bound in ipairs(STEPS) do
    if loss < bound then return i end
  end
  return #STEPS
end

-- Size bins by power lost: 0 below MIN_LOST, then half-decade bins from
-- 1 kW: 1-3 kW, 3-10 kW, 10-30 kW, ... (8 bins, the last one open-ended)
local MIN_LOST = 1000  -- W
local BINS = 8
local function bin_for(lost)
  if not (lost >= MIN_LOST) then return 0 end  -- also catches NaN
  local b = math.floor(2 * math.log(lost / MIN_LOST, 10)) + 1
  if b < 1 then b = 1 end
  if b > BINS then b = BINS end
  return b
end
local function radius_for(b) return 0.8 + 0.4 * b end

local function destroy(id)
  if not id then return end
  local object = rendering.get_object_by_id(id)
  if object and object.valid then object.destroy() end
end

---@return uint[] players, string key
local function viewers()
  local list = {}
  for _, player in pairs(game.connected_players) do
    if player.is_shortcut_toggled(SHORTCUT) then list[#list + 1] = player.index end
  end
  return list, table.concat(list, ",")
end

-- Dots of the "power lost per pole" view, merged into this one in 0.1.3
local function clear_legacy_loss_map()
  local state = storage.loss_map
  if not state then return end
  for _, dot in pairs(state.dots or {}) do destroy(dot.id) end
  storage.loss_map = nil
end

function heatmap_clear()
  clear_legacy_loss_map()
  local state = storage.heatmap
  if not state then return end
  for _, entry in pairs(state.poles) do destroy(entry.id) end
  storage.heatmap = nil
end

-- Recolours and resizes (or draws, or removes) one pole's dot
local function refresh_pole(state, unit, entry)
  local best
  for _, d in pairs(entry.sources) do
    if not best or d < best then best = d end
  end
  if not best or not entry.pole.valid then
    destroy(entry.id)
    state.poles[unit] = nil
    return
  end
  local step = step_for(get_route_line_loss(best))
  local bin = entry.bin or 0
  local object = entry.id and rendering.get_object_by_id(entry.id)
  if object and object.valid then
    if entry.step ~= step then
      object.color = COLOURS[step]
      entry.step = step
    end
    if entry.drawn_bin ~= bin then
      object.radius = radius_for(bin)
      entry.drawn_bin = bin
    end
  else
    entry.id = rendering.draw_circle{
      color = COLOURS[step],
      radius = radius_for(bin),
      filled = true,
      target = entry.pole,
      surface = entry.pole.surface,
      players = state.players,
      render_mode = "chart",
    }.id
    entry.step, entry.drawn_bin = step, bin
  end
end

-- A search finished: settled = {{pole, distance}, ...} from this source
---@param source UnitNumber
---@param settled table
function heatmap_apply(source, settled)
  local state = storage.heatmap
  if not state then return end
  local poles = state.poles
  local previous = state.by_source[source] or {}
  local current = {}
  for _, item in ipairs(settled) do
    local pole, d = item[1], item[2]
    if pole.valid then
      local unit = pole.unit_number
      current[unit] = true
      local entry = poles[unit]
      if not entry then
        entry = {pole = pole, sources = {}}
        poles[unit] = entry
      end
      entry.sources[source] = d
      refresh_pole(state, unit, entry)
    end
  end
  -- Poles this source no longer reaches
  for unit in pairs(previous) do
    if not current[unit] then
      local entry = poles[unit]
      if entry then
        entry.sources[source] = nil
        refresh_pole(state, unit, entry)
      end
    end
  end
  state.by_source[source] = current
end

---@param source UnitNumber
function heatmap_forget_source(source)
  local state = storage.heatmap
  if not state then return end
  for unit in pairs(state.by_source[source] or {}) do
    local entry = state.poles[unit]
    if entry then
      entry.sources[source] = nil
      refresh_pole(state, unit, entry)
    end
  end
  state.by_source[source] = nil
end

-- Load per pole for each owning transformer: weights per machine type, or
-- the even share
local function owner_load_info(parts, tick)
  local info = {}
  local pole_out = parts.pole_out
  if not (pole_out and pole_out.valid) then return info end
  if storage.settings.machine_weighting and parts.line_types then
    info.weights = machine_type_weights(pole_out, type_totals(parts.line_types), tick)
  end
  if not info.weights and (parts.line_n or 0) > 0 then
    info.even = get_network_loads(pole_out, tick).machines / parts.line_n
  end
  return info
end

-- Power lost delivering a pole's machine load, from its owner (W)
local function pole_lost(entry, per_owner, tick)
  local owner = entry.owner
  local parts = owner and storage.transformers[owner]
  if not parts then return 0 end
  local info = per_owner[owner]
  if not info then
    info = owner_load_info(parts, tick)
    per_owner[owner] = info
  end
  local load = 0
  if info.weights then
    for name, count in pairs(entry.m or {}) do
      local w = info.weights[name]
      if w then load = load + w * count end
    end
  elseif info.even and not entry.ns then
    load = info.even
  end
  local loss = get_route_line_loss(entry.s[owner] or 0)
  return loss < 1 and load * loss / (1 - loss) or 0
end

-- Sizes from the current loads
---@param tick GameTick
local function resize(state, tick)
  local pole_dist = storage.pole_dist or {}
  local per_owner = {}
  for unit, entry in pairs(state.poles) do
    local owned = pole_dist[unit]
    entry.bin = owned and bin_for(pole_lost(owned, per_owner, tick)) or 0
    refresh_pole(state, unit, entry)
  end
end

---@param tick GameTick
local function sync(tick)
  local players, key = viewers()
  if #players == 0 or not storage.settings.enabled then
    heatmap_clear()
    return
  end
  local state = storage.heatmap
  if not state then
    state = {poles = {}, by_source = {}, players = players, key = key}
    storage.heatmap = state
    -- Every search runs again and reports its poles
    mark_all_line_loss_dirty()
    return
  end
  if state.key ~= key then
    state.players, state.key = players, key
    for _, entry in pairs(state.poles) do
      local object = entry.id and rendering.get_object_by_id(entry.id)
      if object and object.valid then object.players = players end
    end
  end
  resize(state, tick)
end

---@param player LuaPlayer
---@param tick GameTick
function toggle_heatmap(player, tick)
  player.set_shortcut_toggled(SHORTCUT, not player.is_shortcut_toggled(SHORTCUT))
  sync(tick or game.tick)
end

---@param tick GameTick
function update_heatmap(tick)
  if tick % UPDATE_INTERVAL ~= 0 then return end
  clear_legacy_loss_map()
  sync(tick)
end
