-- Panel next to an opened transformer (attached to the power switch window,
-- like Power Overload's own transformer panel):
--   Upstream: line loss of the last segment, and the same
--     compounded from the generators down (cumulative)
--   Downstream: downstream line loss and power lost
--   This transformer: inefficiency and core loss (both charged on the
--     upstream network), drawing, output
-- Refreshed every UPDATE_INTERVAL ticks while open.

local FRAME_NAME = "line-loss-transformer-panel"
local UPDATE_INTERVAL = 30

local function percent(x) return string.format("%.1f", x * 100) end

---@param player LuaPlayer
local function close_panel(player)
  local frame = player.gui.relative[FRAME_NAME]
  if frame then frame.destroy() end
end

local function header(content, caption)
  local l = content.add{type = "label", caption = caption, style = "caption_label"}
  l.style.top_margin = 4
end

local function row(content, caption, tooltip)
  content.add{type = "label", caption = caption, tooltip = tooltip}
end

---@param frame LuaGuiElement
---@param entity LuaEntity
local function fill(frame, entity)
  local content = frame.content
  content.clear()
  local parts = storage.transformers[entity.unit_number]
  if not parts then
    content.add{type = "label", caption = {"line-loss-panel.not-tracked"}}
    return
  end
  local format = shared.format_energy_number
  local s = storage.settings

  if s.enabled then
    -- Upstream
    header(content, {"line-loss-panel.section-in"})
    local loss_in = get_upstream_line_loss(entity.unit_number)
    if loss_in and (parts.gen_burn or 0) > 0 then
      row(content, {"line-loss-panel.incoming-gen", percent(loss_in), format(parts.gen_burn)}, {"line-loss-panel.incoming-gen-tooltip"})
    elseif loss_in then
      row(content, {"line-loss-panel.incoming", percent(loss_in)}, {"line-loss-panel.incoming-tooltip"})
    else
      row(content, {"line-loss-panel.incoming-none"}, {"line-loss-panel.incoming-tooltip"})
    end
    local total_in = get_cumulative_line_loss(entity.unit_number)
    if total_in then
      row(content, {"line-loss-panel.cumulative", percent(total_in)}, {"line-loss-panel.cumulative-tooltip"})
    end
    -- Downstream
    header(content, {"line-loss-panel.section-out"})
    if parts.line_distance then
      row(content, {"line-loss-panel.outgoing", percent(parts.line_loss or 0), format(parts.line_burn or 0)},
        {"line-loss-panel.outgoing-tooltip"})
    else
      row(content, {"line-loss-panel.calculating"}, {"line-loss-panel.outgoing-tooltip"})
    end
  else
    row(content, {"line-loss-panel.disabled"})
  end
  -- This transformer
  header(content, {"line-loss-panel.section-self"})
  row(content, {"line-loss-panel.ineff", format(parts.ineff_burn or 0)}, {"line-loss-panel.ineff-tooltip"})
  if parts.rating then
    row(content, {"line-loss-panel.no-load", format(parts.no_load_burn or 0), string.format("%g", s.no_load * 100), format(parts.rating)},
      {"line-loss-panel.no-load-tooltip"})
  end
  row(content, {"line-loss-panel.drawing", format(parts.p_draw or 0)}, {"line-loss-panel.drawing-tooltip"})
  row(content, {"line-loss-panel.output", format(parts.p_out or 0)}, {"line-loss-panel.output-tooltip"})
end

---@param player LuaPlayer
---@param entity LuaEntity
local function open_panel(player, entity)
  close_panel(player)
  local frame = player.gui.relative.add{
    type = "frame",
    name = FRAME_NAME,
    direction = "vertical",
    caption = {"line-loss-panel.title"},
    anchor = {
      gui = defines.relative_gui_type.power_switch_gui,
      position = defines.relative_gui_position.right,
      names = TRANSFORMER_NAME_LIST,
    },
  }
  frame.add{type = "frame", name = "content", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  fill(frame, entity)
end

---@param event EventData.on_gui_opened
function transformer_panel_on_opened(event)
  local entity = event.entity
  if not (entity and entity.valid and TRANSFORMER_NAMES[entity.name]) then return end
  local player = game.get_player(event.player_index)
  if player then open_panel(player, entity) end
end

---@param event EventData.on_gui_closed
function transformer_panel_on_closed(event)
  local entity = event.entity
  if not (entity and entity.valid and TRANSFORMER_NAMES[entity.name]) then return end
  local player = game.get_player(event.player_index)
  if player then close_panel(player) end
end

---@param tick GameTick
function update_transformer_panels(tick)
  if tick % UPDATE_INTERVAL ~= 0 then return end
  for _, player in pairs(game.connected_players) do
    local frame = player.gui.relative[FRAME_NAME]
    if frame then
      local opened = player.opened
      if opened and opened.object_name == "LuaEntity" and opened.valid and TRANSFORMER_NAMES[opened.name] then
        fill(frame, opened)
      else
        frame.destroy()
      end
    end
  end
end
