-- Panel next to an opened transformer (attached to the power switch window,
-- like Power Overload's own transformer panel):
-- A segment is the wires between two transformers, or between the
-- generators and a transformer.
--   Opener (a short list): "feed nearest consumers first" on/off, machine
--     weighting on/off, and what feeds this transformer (n transformers or
--     n generators) at what average resistance-weighted distance
--   Upstream (shares of the power generated for this transformer), laid out
--     like Downstream: generated for it; minus lines, inefficiency and core
--     loss of every segment and transformer on the way; equals power
--     received (= Input below); total loss (the sum); then the line loss
--     of the last segment
--   Downstream (shares of its input): input; minus the next segment's line
--     loss, its inefficiency and its core loss; equals output (delivered
--     to the next segment's consumers); total loss (the sum, optionally with
--     input - output next to it as a check)
-- Every row is "power (percentage)"; with a per-player setting, all power in
-- the unit of the panel's largest figure. Tooltips carry the definitions and the
-- live figures (core loss: rating and the poles that set it).
--   Hover information: the values shown when hovering this transformer, for
--     every player (hover.lua)
-- The figures are refreshed every UPDATE_INTERVAL ticks while open; the hover
-- options are built once per opening, so a click is never lost to a refresh.

local FRAME_NAME = "line-loss-transformer-panel"
local UPDATE_INTERVAL = 30

local function percent(x) return string.format("%.1f", x * 100) end

---@param player LuaPlayer
local function close_panel(player)
  local frame = player.gui.relative[FRAME_NAME]
  if frame then frame.destroy() end
end

local function header(content, caption, tooltip)
  local l = content.add{type = "label", caption = caption, style = "caption_label", tooltip = tooltip}
  l.style.top_margin = 4
end

local function row(content, caption, tooltip)
  return content.add{type = "label", caption = caption, tooltip = tooltip}
end

local function bold(label)
  label.style.font = "default-bold"
  return label
end

local function sub_row(content, caption, tooltip)
  row(content, caption, tooltip).style.left_padding = 12
end

HOVER_OPTION_UP = "line-loss-hover-option-up"
HOVER_OPTION_DOWN = "line-loss-hover-option-down"

-- Power and percentage, "45kW (12.3%)". Each figure in its own unit, or, with
-- the per-player setting on, all in the unit of the panel's largest figure
-- (set by fill before the rows are built; nil = own unit)
local panel_unit
local function power(watts)
  if panel_unit then return ratings.format_power_in(watts, panel_unit) end
  return ratings.format_power(watts)
end
local function share_and_power(share, watts)
  return {"line-loss-panel.share-power", percent(share), power(watts)}
end

---@param parts table
---@return LocalisedString
local function core_loss_tooltip(parts, s)
  local format = ratings.format_power
  local text = {"", {"line-loss-panel.core-tooltip", string.format("%g", s.no_load * 100), format(parts.rating or 0), format(parts.no_load_burn or 0)}}
  local up, down = parts.rating_in, parts.rating_out
  if up and down then
    text[#text + 1] = "\n\n"
    text[#text + 1] = {"line-loss-panel.core-tooltip-rating",
      {"entity-name." .. up.name}, format(up.w), {"entity-name." .. down.name}, format(down.w), format(parts.rating or 0)}
  end
  text[#text + 1] = "\n\n"
  text[#text + 1] = {"line-loss-panel.core-tooltip-advice"}
  return text
end

---@param frame LuaGuiElement
---@param entity LuaEntity
---@param player LuaPlayer
local function fill(frame, entity, player)
  local content = frame.content
  content.clear()
  local parts = storage.transformers[entity.unit_number]
  if not parts then
    content.add{type = "label", caption = {"line-loss-panel.not-tracked"}}
    return
  end
  local format = power
  local s = storage.settings
  local draw, out = parts.p_draw or 0, parts.p_deliv or 0
  -- One unit for the whole panel: the one that suits its largest figure
  local largest = math.max(draw, out, parts.gen_burn or 0)
  local total_up = s.enabled and get_cumulative_upstream_loss(entity.unit_number)
  if total_up and total_up < 1 then largest = math.max(largest, draw / (1 - total_up)) end
  local same_unit = player.mod_settings["line-loss-panel-same-unit"]
  panel_unit = (same_unit and same_unit.value) and ratings.power_unit(largest) or nil

  if s.enabled then
    -- Opener: the two model settings, then what feeds this transformer
    local function state(on) return {"line-loss-panel.state-" .. (on and "on" or "off")} end
    row(content, {"line-loss-panel.opener-matching", state(s.closeness)})
    row(content, {"line-loss-panel.opener-weighting", state(s.machine_weighting)})
    local kind, n, d = get_feeder_summary(entity.unit_number)
    local fed
    if kind then
      fed = {"line-loss-panel.fed-by-" .. kind .. (n == 1 and "-one" or ""), n, string.format("%d", math.floor((d or 0) + 0.5))}
    else
      fed = {"line-loss-panel.fed-by-unknown"}
    end
    local fed_label = row(content, fed)
    fed_label.style.single_line = false
    fed_label.style.maximal_width = 360

    -- Upstream, laid out like Downstream: generated for this transformer,
    -- minus the losses on the way, equals the power received. Shares of the
    -- power generated for it.
    header(content, {"line-loss-panel.section-in"}, {"line-loss-panel.section-in-tooltip"})
    local total, line, ineff, core = get_cumulative_upstream_loss(entity.unit_number)
    if total and total < 1 then
      local generated = draw / (1 - total)
      row(content, {"line-loss-panel.generated", format(generated)})
      sub_row(content, {"line-loss-panel.part-line-minus", share_and_power(line, generated * line)}, {"line-loss-panel.upstream-part-tooltip"})
      sub_row(content, {"line-loss-panel.part-ineff-minus", share_and_power(ineff, generated * ineff)}, {"line-loss-panel.upstream-part-tooltip"})
      sub_row(content, {"line-loss-panel.part-core-minus", share_and_power(core, generated * core)}, {"line-loss-panel.upstream-part-tooltip"})
      row(content, {"line-loss-panel.received", share_and_power(1 - total, draw)}, {"line-loss-panel.received-tooltip"})
      bold(row(content, {"line-loss-panel.total-loss-up", share_and_power(total, generated * total)},
        {"line-loss-panel.total-loss-up-tooltip", format(generated * total), format(draw)}))
    end
    local loss_in = get_upstream_line_loss(entity.unit_number)
    if loss_in and (parts.gen_burn or 0) > 0 then
      row(content, {"line-loss-panel.incoming-gen", percent(loss_in), format(parts.gen_burn)}, {"line-loss-panel.incoming-gen-tooltip"})
    elseif loss_in then
      row(content, {"line-loss-panel.incoming", percent(loss_in)}, {"line-loss-panel.incoming-tooltip"})
    else
      row(content, {"line-loss-panel.incoming-none"}, {"line-loss-panel.incoming-tooltip"})
    end
  end

  -- Downstream: from this transformer's input to the consumers of its next
  -- segment; shares of its input
  header(content, {"line-loss-panel.section-out"}, {"line-loss-panel.section-out-tooltip"})
  row(content, {"line-loss-panel.input", format(draw)}, {"line-loss-panel.input-tooltip"})
  local function of_input(w) return draw > 0 and w / draw or 0 end
  local line_w = s.enabled and (parts.line_burn or 0) or 0
  if s.enabled then
    if parts.line_distance then
      sub_row(content, {"line-loss-panel.part-line-next", share_and_power(of_input(line_w), line_w)}, {"line-loss-panel.outgoing-tooltip"})
    else
      sub_row(content, {"line-loss-panel.calculating"}, {"line-loss-panel.outgoing-tooltip"})
    end
  else
    sub_row(content, {"line-loss-panel.disabled"})
  end
  local ineff_w, core_w = parts.ineff_burn or 0, parts.no_load_burn or 0
  sub_row(content, {"line-loss-panel.part-ineff-minus", share_and_power(of_input(ineff_w), ineff_w)}, {"line-loss-panel.ineff-tooltip"})
  sub_row(content, {"line-loss-panel.part-core-minus", share_and_power(of_input(core_w), core_w)}, core_loss_tooltip(parts, s))
  row(content, {"line-loss-panel.output", share_and_power(of_input(out), out)}, {"line-loss-panel.output-tooltip"})
  -- Sum of the losses; input - output must give the same (Power Overload's
  -- own efficiency is 1). A per-player setting shows it as a check.
  local lost = line_w + ineff_w + core_w
  local setting = player.mod_settings["line-loss-show-loss-check"]
  local total_row
  if setting and setting.value then
    total_row = row(content, {"line-loss-panel.total-loss-check", share_and_power(of_input(lost), lost), format(draw - out)},
      {"line-loss-panel.total-loss-tooltip", format(line_w), format(ineff_w), format(core_w), format(lost)})
  else
    total_row = row(content, {"line-loss-panel.total-loss", share_and_power(of_input(lost), lost)},
      {"line-loss-panel.total-loss-tooltip", format(line_w), format(ineff_w), format(core_w), format(lost)})
  end
  bold(total_row)
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
  fill(frame, entity, player)
  -- Hover information: not part of the refreshed content
  local parts = storage.transformers[entity.unit_number]
  if not parts then return end
  local options = get_hover_options(parts)
  local box = frame.add{type = "frame", name = "hover_options", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  box.style.top_margin = 8
  box.add{type = "label", caption = {"line-loss-panel.hover-title"}, style = "caption_label", tooltip = {"line-loss-panel.hover-title-tooltip"}}
  box.add{type = "checkbox", name = HOVER_OPTION_UP, state = options.up, caption = {"line-loss-panel.hover-up"}}
  box.add{type = "checkbox", name = HOVER_OPTION_DOWN, state = options.down, caption = {"line-loss-panel.hover-down"}}
end

---@param event EventData.on_gui_opened
function transformer_panel_on_opened(event)
  local entity = event.entity
  if not (entity and entity.valid and TRANSFORMER_NAMES[entity.name]) then return end
  local player = game.get_player(event.player_index)
  if player then
    open_panel(player, entity)
    feed_paths_set_target(player.index, entity.unit_number)
  end
end

---@param event EventData.on_gui_checked_state_changed
function transformer_panel_on_checked(event)
  local element = event.element
  if not (element and element.valid) then return end
  local key = element.name == HOVER_OPTION_UP and "up" or element.name == HOVER_OPTION_DOWN and "down"
  if not key then return end
  -- the transformer whose panel this is
  local player = game.get_player(event.player_index)
  local opened = player and player.opened
  if not (opened and opened.object_name == "LuaEntity" and opened.valid and TRANSFORMER_NAMES[opened.name]) then return end
  set_hover_option(opened.unit_number, key, element.state)
  -- other players with this transformer open see the new state
  for _, other in pairs(game.connected_players) do
    local o = other.opened
    if other.index ~= player.index and o and o.object_name == "LuaEntity" and o.valid and o.unit_number == opened.unit_number then
      local frame = other.gui.relative[FRAME_NAME]
      local box = frame and frame.hover_options
      local checkbox = box and box[element.name]
      if checkbox then checkbox.state = element.state end
    end
  end
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
        fill(frame, opened, player)
      else
        frame.destroy()
      end
    end
  end
end
