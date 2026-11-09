-- Loss map: every pole on the map gets a dot sized and coloured by the power
-- lost delivering the machine load on it, from the transformer that owns the
-- pole (its electrically nearest source): lost = load * L / (1 - L), with L
-- the capped route loss to that pole.
-- Load per pole: with "weight machines by their live load" on, the machines
-- in its supply area times what each machine type draws right now; otherwise
-- the network's machine load spread evenly over its poles.
--
-- Map view only, per player, toggled with its shortcut (off by default).
-- Downstream networks of transformers only: generator networks and
-- downstream transformers are not drawn (the grid diagram shows those).

local SHORTCUT = "line-loss-toggle-loss-map"
local UPDATE_INTERVAL = 60
local MIN_LOST = 1000  -- W: below this no dot is drawn

-- Half-decade bins from 1 kW: 1-3 kW, 3-10 kW, 10-30 kW, ... (8 bins, the
-- last one open-ended), each with a radius and a colour from yellow to red
local BINS = 8
local function bin_for(lost)
  local b = math.floor(2 * math.log(lost / MIN_LOST, 10)) + 1
  if b < 1 then b = 1 end
  if b > BINS then b = BINS end
  return b
end
local function radius_for(b) return 0.6 + 0.45 * (b - 1) end
local COLOURS = {
  {r = 1.00, g = 0.95, b = 0.30},
  {r = 1.00, g = 0.85, b = 0.20},
  {r = 1.00, g = 0.72, b = 0.15},
  {r = 1.00, g = 0.58, b = 0.12},
  {r = 1.00, g = 0.45, b = 0.12},
  {r = 1.00, g = 0.32, b = 0.15},
  {r = 0.92, g = 0.18, b = 0.18},
  {r = 0.75, g = 0.05, b = 0.20},
}

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

function loss_map_clear()
  local state = storage.loss_map
  if not state then return end
  for _, dot in pairs(state.dots) do destroy(dot.id) end
  storage.loss_map = nil
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

---@param tick GameTick
local function refresh(state, tick)
  local transformers = storage.transformers
  local per_owner = {}
  local seen = {}
  for unit, entry in pairs(storage.pole_dist or {}) do
    local pole, owner = entry.pole, entry.owner
    local parts = owner and transformers[owner]
    if pole and pole.valid and parts then
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
      elseif info.even then
        load = info.even
      end
      local loss = get_route_line_loss(entry.s[owner] or 0)
      local lost = loss < 1 and load * loss / (1 - loss) or 0
      if lost >= MIN_LOST then
        seen[unit] = true
        local b = bin_for(lost)
        local dot = state.dots[unit]
        local object = dot and rendering.get_object_by_id(dot.id)
        if object and object.valid then
          if dot.bin ~= b then
            object.color = COLOURS[b]
            object.radius = radius_for(b)
            dot.bin = b
          end
        else
          object = rendering.draw_circle{
            color = COLOURS[b], radius = radius_for(b), filled = true,
            target = pole, surface = pole.surface, players = state.players,
            render_mode = "chart",
          }
          state.dots[unit] = {id = object.id, bin = b}
        end
      end
    end
  end
  for unit, dot in pairs(state.dots) do
    if not seen[unit] then
      destroy(dot.id)
      state.dots[unit] = nil
    end
  end
end

---@param tick GameTick
---@param force boolean?
local function sync(tick, force)
  local players, key = viewers()
  if #players == 0 or not storage.settings.enabled then
    loss_map_clear()
    return
  end
  local state = storage.loss_map
  if not state then
    state = {dots = {}, players = players, key = key}
    storage.loss_map = state
    -- Older saves have no pole references yet: search everything again
    mark_all_line_loss_dirty()
  elseif state.key ~= key then
    state.players, state.key = players, key
    for _, dot in pairs(state.dots) do
      local object = rendering.get_object_by_id(dot.id)
      if object and object.valid then object.players = players end
    end
  end
  if force or tick % UPDATE_INTERVAL == 0 then refresh(state, tick) end
end

---@param player LuaPlayer
---@param tick GameTick
function toggle_loss_map(player, tick)
  player.set_shortcut_toggled(SHORTCUT, not player.is_shortcut_toggled(SHORTCUT))
  sync(tick, true)
end

---@param tick GameTick
function update_loss_map(tick)
  if tick % UPDATE_INTERVAL ~= 0 then return end
  sync(tick)
end
