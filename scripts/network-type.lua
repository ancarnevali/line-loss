-- A frame below the electric network window (opened from a pole): whether the
-- pole's network is solved as transmission or distribution. Same placement as
-- the kWh Tooltips mod's panel.

local FRAME = "line-loss-network-type"

---@param player LuaPlayer
local function destroy(player)
  local old = player.gui.relative[FRAME]
  if old then old.destroy() end
end

---@param player LuaPlayer
---@param pole LuaEntity
local function show(player, pole)
  destroy(player)
  local kind = kirchhoff_network_kind(pole.unit_number)
  local frame = player.gui.relative.add{
    type = "frame", name = FRAME, direction = "vertical",
    anchor = {gui = defines.relative_gui_type.electric_network_gui, position = defines.relative_gui_position.bottom},
  }
  frame.add{type = "label", caption = {"line-loss-network." .. (kind or "unknown")},
    tooltip = network_kind_tooltip(kind, pole.unit_number)}
end

---@param event EventData.on_gui_opened
function network_type_on_opened(event)
  local entity = event.entity
  if not (entity and entity.valid and entity.type == "electric-pole") then return end
  local player = game.get_player(event.player_index)
  if player then show(player, entity) end
end

---@param event EventData.on_gui_closed
function network_type_on_closed(event)
  local player = game.get_player(event.player_index)
  if player then destroy(player) end
end
