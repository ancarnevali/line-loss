-- Text under a hovered transformer:
--   Drawing: <power drawn from the upstream network>
--   Loss upstream: <total upstream loss>%       (option, on by default)
--   Loss downstream: <line loss in the next segment>% (option, off by default)
-- A segment is the wires between two transformers (or between the generators
-- and a transformer). The loss values are chosen per transformer, for every
-- player, in its panel ("Hover information"); they share the second line,
-- each coloured by its own value: green below 10%, yellow below 50%, red
-- above.
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

local TEXT_COLOUR = {r = 1, g = 1, b = 1}
local RICH_COLOURS = {ok = "0,1,0", near = "1,1,0", over = "1,0,0"}

local function colour_key_of(loss)
  if loss >= 0.5 then return "over" end
  if loss >= 0.1 then return "near" end
  return "ok"
end

-- Per transformer, kept in its storage entry (so it goes with it):
-- hover_up (default on) and hover_down (default off).
---@param parts table
---@return table  {up = boolean, down = boolean}
function get_hover_options(parts)
  return {up = parts.hover_up ~= false, down = parts.hover_down == true}
end

---@param unit UnitNumber
---@param key "up"|"down"
---@param value boolean
function set_hover_option(unit, key, value)
  local parts = storage.transformers[unit]
  if not parts then return end
  if key == "up" then parts.hover_up = value else parts.hover_down = value end
  -- every player hovering it redraws at the next tick
  storage.hover_selected = {}
end

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
---@return LocalisedString? line1, LocalisedString? line2, string? key
local function transformer_info(transformer)
  if not storage.settings.enabled then return nil end
  local parts = storage.transformers[transformer.unit_number]
  if not parts then return nil end
  local options = get_hover_options(parts)
  local drawing = ratings.format_power(parts.p_draw or 0)
  local line2, key = {""}, drawing
  local function add(locale_key, loss)
    local value = string.format("%.1f%%", loss * 100)
    if #line2 > 1 then line2[#line2 + 1] = "    " end
    line2[#line2 + 1] = {"", "[color=" .. RICH_COLOURS[colour_key_of(loss)] .. "]", {locale_key, value}, "[/color]"}
    key = key .. "|" .. locale_key .. value
  end
  if options.up then
    add("line-loss.hover-upstream", get_cumulative_upstream_loss(transformer.unit_number) or 0)
  end
  if options.down then
    add("line-loss.hover-downstream", parts.line_loss or 0)
  end
  return {"line-loss.drawing-hover", drawing}, line2, key
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
  local line1, line2, key
  if transformer then
    line1, line2, key = transformer_info(transformer)
    feed_paths_set_target(player_index, transformer.unit_number)
  end

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
  else
    clear_player_info(player_index)
    local function draw(text, vertical_alignment)
      return rendering.draw_text{
        text = text,
        surface = transformer.surface,
        target = {entity = transformer, offset = {x = 0, y = ANCHOR_Y}},
        color = TEXT_COLOUR,
        scale = 1.5 * player.display_scale,
        alignment = "center",
        vertical_alignment = vertical_alignment,
        scale_with_zoom = true,
        use_rich_text = true,
        players = {player},
      }.id
    end
    infos[player_index] = {
      id = draw(line1, "bottom"),
      id2 = draw(line2, "top"),
      unit_number = transformer.unit_number,
      key = key,
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
