-- Pole heatmap: every pole on the map gets a dot coloured by the line loss of
-- the power reaching it from the nearest transformer feeding its network
-- (route loss of the shortest resistance-weighted path). Shows which stretch
-- of poles is costing power.
--
-- Map view only, per player, toggled with the "Toggle line-loss heatmap"
-- shortcut. Data is kept only while someone has it on: the searches record
-- the poles they settle (line-losses.lua) and hand them over here. Turning it
-- on re-runs every search, so the map fills in within a few seconds.

local SHORTCUT = "line-loss-toggle-heatmap"
local UPDATE_INTERVAL = 60
local DOT_RADIUS = 1.2

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

function heatmap_clear()
  local state = storage.heatmap
  if not state then return end
  for _, entry in pairs(state.poles) do destroy(entry.id) end
  storage.heatmap = nil
end

-- Recolours (or draws, or removes) one pole's dot from its sources' distances
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
  local object = entry.id and rendering.get_object_by_id(entry.id)
  if object and object.valid then
    if entry.step ~= step then
      object.color = COLOURS[step]
      entry.step = step
    end
  else
    entry.id = rendering.draw_circle{
      color = COLOURS[step],
      radius = DOT_RADIUS,
      filled = true,
      target = entry.pole,
      surface = entry.pole.surface,
      players = state.players,
      render_mode = "chart",
    }.id
    entry.step = step
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

---@param force boolean?
local function sync(force)
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
  if force then
    -- Per-tile setting changed: recolour everything
    for unit, entry in pairs(state.poles) do refresh_pole(state, unit, entry) end
  end
end

---@param player LuaPlayer
function toggle_heatmap(player)
  player.set_shortcut_toggled(SHORTCUT, not player.is_shortcut_toggled(SHORTCUT))
  sync()
end

---@param tick GameTick
function update_heatmap(tick)
  if tick % UPDATE_INTERVAL ~= 0 then return end
  sync()
end
