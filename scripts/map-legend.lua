-- Legend window for the map views (heatmap, power lost per pole), shown while
-- a player has either on. Left edge of the screen, draggable, position
-- remembered per player.

local FRAME = "line-loss-map-legend"
local HEATMAP = "line-loss-toggle-heatmap"
local LOSS_MAP = "line-loss-toggle-loss-map"

local function build(player, heat, loss)
  local frame = player.gui.screen[FRAME]
  if frame then frame.destroy() end
  frame = player.gui.screen.add{type = "frame", name = FRAME, direction = "vertical"}
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", caption = {"line-loss-legend.title"}, style = "frame_title", ignored_by_interaction = true}
  local handle = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  handle.style.horizontally_stretchable = true
  handle.style.height = 24
  handle.style.minimal_width = 24
  local content = frame.add{type = "flow", direction = "vertical"}
  if heat then
    content.add{type = "label", caption = {"line-loss-legend.heatmap-title"}, style = "caption_label"}
    content.add{type = "label", caption = {"line-loss-legend.heatmap"}}
  end
  if loss then
    content.add{type = "label", caption = {"line-loss-legend.loss-map-title"}, style = "caption_label"}
    local l = content.add{type = "label", caption = {"line-loss-legend.loss-map"}}
    if not storage.settings.machine_weighting then
      local note = content.add{type = "label", caption = {"line-loss-legend.loss-map-even"}}
      note.style.single_line = false
      note.style.maximal_width = 300
    end
  end
  local saved = storage.legend_location and storage.legend_location[player.index]
  frame.location = saved or {x = 0, y = math.floor(player.display_resolution.height * 0.62)}
  return frame
end

---@param tick GameTick
---@param force boolean?
function update_map_legend(tick, force)
  if not force and tick % 60 ~= 0 then return end
  for _, player in pairs(game.connected_players) do
    local heat = player.is_shortcut_toggled(HEATMAP)
    local loss = player.is_shortcut_toggled(LOSS_MAP)
    local frame = player.gui.screen[FRAME]
    if heat or loss then
      local key = (heat and "h" or "") .. (loss and "l" or "") .. (storage.settings.machine_weighting and "w" or "")
      storage.legend_keys = storage.legend_keys or {}
      if not frame or storage.legend_keys[player.index] ~= key then
        build(player, heat, loss)
        storage.legend_keys[player.index] = key
      end
    elseif frame then
      frame.destroy()
      if storage.legend_keys then storage.legend_keys[player.index] = nil end
    end
  end
end
