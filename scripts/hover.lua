-- Text under a hovered transformer, two lines in one colour:
--   Drawing: <power drawn from the upstream network>
--   Line loss: <upstream line loss of the last segment>%
-- Coloured by that last-segment line loss, with the same thresholds as the
-- grid diagram's diamonds: green below 10%, yellow below 50%, red above.
-- The cumulative line loss is in the transformer panel only.
-- Two text objects that keep the same size on screen at every zoom level,
-- like Power Overload's pole readout.
-- Both hang off the same anchor point: the first line sits on it
-- (vertical alignment "bottom"), the second hangs under it ("top"). An offset
-- in tiles would change the gap between them with zoom; a shared anchor
-- keeps it constant on screen.

-- Recomputed when the selection changes, and otherwise only this often (the
-- figures themselves change once a second)
local REFRESH_INTERVAL = 30

-- Anchor between the two text objects, in tiles below the transformer's centre
-- (its bottom edge is at 1)
local ANCHOR_Y = 1.3

local COLOURS = {
  ok = {r = 0, g = 1, b = 0},
  near = {r = 1, g = 1, b = 0},
  over = {r = 1, g = 0, b = 0},
}

-- The transformer's hidden in/out poles sit on top of it with a higher
-- selection priority, so hovering a transformer usually selects one of them.
local HIDDEN_TRANSFORMER_POLES = {
  ["po-hidden-electric-pole-in"] = true,
  ["po-hidden-electric-pole-out"] = true,
}

-- player index -> {unit_number, transformer}: hidden pole -> transformer.
-- Only avoids repeating the lookup every tick, so it does not live in storage.
local hover_cache = {}

---@param player_index uint
---@param hidden_pole LuaEntity
---@return LuaEntity?
local function transformer_of_hidden_pole(player_index, hidden_pole)
  local cache = hover_cache[player_index]
  if cache and cache.unit_number == hidden_pole.unit_number and cache.transformer.valid then
    return cache.transformer
  end
  local transformer = hidden_pole.surface.find_entities_filtered{
    position = hidden_pole.position, radius = 1, name = TRANSFORMER_NAME_LIST, limit = 1,
  }[1]
  hover_cache[player_index] = transformer and {unit_number = hidden_pole.unit_number, transformer = transformer} or nil
  return transformer
end

---@param transformer LuaEntity
---@return LocalisedString? line1, LocalisedString? line2, string? key, string? colour_key
local function transformer_info(transformer)
  if not storage.settings.enabled then return nil end
  local parts = storage.transformers[transformer.unit_number]
  if not parts then return nil end
  -- nil: not fed through another transformer (e.g. straight from generators),
  -- so no line loss is modelled upstream of it
  local loss = get_upstream_line_loss(transformer.unit_number) or 0
  -- Same thresholds as the grid diagram's diamonds (grid-diagram.lua band_for)
  local colour_key = "ok"
  if loss >= 0.5 then
    colour_key = "over"
  elseif loss >= 0.1 then
    colour_key = "near"
  end
  local value = string.format("%.1f", loss * 100)
  local drawing = shared.format_energy_number(parts.p_draw or 0)
  return {"line-loss.drawing-hover", drawing},
    {"line-loss.line-loss-hover", value},
    drawing .. "|" .. value, colour_key
end

local function destroy(id)
  if not id then return end
  local object = rendering.get_object_by_id(id)
  if object and object.valid then object.destroy() end
end

local function clear_player_info(player_index)
  local info = storage.hover_info[player_index]
  if not info then return end
  destroy(info.id)
  destroy(info.id2)
  storage.hover_info[player_index] = nil
end

function reset_hover()
  for _, info in pairs(storage.hover_info or {}) do
    destroy(info.id)
    destroy(info.id2)
  end
  storage.hover_info = {}
  storage.hover_selected = {}
  hover_cache = {}
end

---@param player LuaPlayer
---@param selected LuaEntity
local function refresh_player(player, selected)
  local infos = storage.hover_info
  local player_index = player.index
  local transformer
  if selected.force == player.force then
    local name = selected.name
    if HIDDEN_TRANSFORMER_POLES[name] then
      transformer = transformer_of_hidden_pole(player_index, selected)
    elseif TRANSFORMER_NAMES[name] then
      transformer = selected
    end
  end
  local line1, line2, key, colour_key
  if transformer then line1, line2, key, colour_key = transformer_info(transformer) end

  if not line1 then
    clear_player_info(player_index)
    return
  end
  local info = infos[player_index]
  local object = info and rendering.get_object_by_id(info.id)
  local object2 = info and info.id2 and rendering.get_object_by_id(info.id2)
  if object and object.valid and object2 and object2.valid and info.unit_number == transformer.unit_number then
    if info.key ~= key then
      object.text = line1
      object2.text = line2
      info.key = key
    end
    if info.colour_key ~= colour_key then
      object.color = COLOURS[colour_key]
      object2.color = COLOURS[colour_key]
      info.colour_key = colour_key
    end
  else
    clear_player_info(player_index)
    local function draw(text, vertical_alignment)
      return rendering.draw_text{
        text = text,
        surface = transformer.surface,
        target = {entity = transformer, offset = {x = 0, y = ANCHOR_Y}},
        color = COLOURS[colour_key],
        scale = 1.5 * player.display_scale,
        alignment = "center",
        vertical_alignment = vertical_alignment,
        scale_with_zoom = true,
        players = {player},
      }.id
    end
    infos[player_index] = {
      id = draw(line1, "bottom"),
      id2 = draw(line2, "top"),
      unit_number = transformer.unit_number,
      key = key,
      colour_key = colour_key,
    }
  end
end

---@param tick GameTick
function update_hover(tick)
  -- player index -> unit number of what the player had selected last tick.
  -- In storage: it decides when drawings change, so every client must agree.
  local last = storage.hover_selected
  if not last then
    last = {}
    storage.hover_selected = last
  end
  local periodic = tick % REFRESH_INTERVAL == 0
  for _, player in pairs(game.connected_players) do
    local player_index = player.index
    local selected = player.selected
    -- Transformers and their hidden poles all have a unit number
    local unit = selected and selected.unit_number
    if not unit then
      if last[player_index] then
        last[player_index] = nil
        clear_player_info(player_index)
      end
    elseif last[player_index] ~= unit or periodic then
      last[player_index] = unit
      refresh_player(player, selected)
    end
  end
end
