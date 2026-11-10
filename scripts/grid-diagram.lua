-- Grid diagram: a one-line schematic of the transformer grid on the map.
--
-- One straight line per route, from each transformer to each downstream
-- transformer downstream of it (the routes found by line-losses.lua):
--   width  = power on the route (the source's delivered power split among
--            its consumers in proportion to their draw, or as assigned by
--            "feed nearest consumers first" when that is on)
--   colour = line loss on the route: green < 10%, yellow < 50%, red above;
--            grey when no power flows
--   label  = "power · loss LL" at the midpoint
-- A diamond marks each receiving transformer, coloured by the line loss of
-- all the power arriving at it (power-weighted over its feeders).
-- A panel (left edge of the screen, draggable) shows the grid's energy balance, averaged over the last 5 s:
-- generated power, power reaching machines, and power lost, split into
-- transformers (inefficiency and core loss) and line losses, each also as %
-- of generation;
-- below it the routes losing the most power, each with a button that opens
-- the map there.
--
-- Map view only, and only for players who switched it on with the
-- "Toggle grid diagram" shortcut (off by default, per player).
--
-- When no connected player has it on, nothing is computed and every drawing
-- is removed.

local UPDATE_INTERVAL = 60
-- Energy-balance window: one sample per update, averaged over this many
local STATS_SAMPLES = 5
local PANEL_NAME = "line-loss-grid-panel"
local DIAMOND_SIZE = 5  -- tiles from centre to tip; marks a receiving transformer
local SHORTCUT = "line-loss-toggle-grid-diagram"

local COLOURS = {
  ok = {r = 0.2, g = 0.9, b = 0.2},
  near = {r = 1, g = 0.85, b = 0.1},
  over = {r = 1, g = 0.2, b = 0.2},
  idle = {r = 0.5, g = 0.5, b = 0.5},
}

local function destroy(id)
  if not id then return end
  local object = rendering.get_object_by_id(id)
  if object and object.valid then object.destroy() end
end

local function destroy_route(route)
  destroy(route.line)
  destroy(route.label)
end

-- Removes every drawing this module made.
function grid_diagram_clear()
  storage.grid_stats = nil
  for _, player in pairs(game.players) do
    destroy_panel(player)
  end
  local state = storage.grid_diagram
  if not state then return end
  for _, route in pairs(state.routes) do
    destroy_route(route)
  end
  for _, diamond in pairs(state.diamonds or {}) do
    destroy(diamond.id)
  end
  storage.grid_diagram = nil
end

-- Energy balance -------------------------------------------------------------
-- On every network a transformer touches, consumption splits into machines
-- (anything that is not a transformer or a loss consumer, accumulators
-- charging included), "Line loss" and "Transf. ineff." consumers, and the
-- transformers' own inputs. Everything generated either reaches a machine or
-- is lost, so
--   generated = machines + line losses + transformer losses
-- where transformer losses also include any loss inside Power Overload's own
-- transfer (when its efficiency is below 1).

---@param tick GameTick
---@return table
local function sample_balance(tick)
  local machines, line, ineff, seen = 0, 0, 0, {}
  local po_loss = 0
  for _, transformer_parts in pairs(storage.transformers) do
    po_loss = po_loss + (transformer_parts.p_in or 0) - (transformer_parts.p_out or 0)
    for _, pole in pairs({transformer_parts.pole_in, transformer_parts.pole_out}) do
      if pole and pole.valid then
        local network_id = pole.electric_network_id
        if network_id and not seen[network_id] then
          seen[network_id] = true
          local loads = get_network_loads(pole, tick)
          machines = machines + loads.machines
          line = line + loads.line
          ineff = ineff + loads.ineff
        end
      end
    end
  end
  if po_loss < 0 then po_loss = 0 end
  return {machines = machines, line = line, transformer = ineff + po_loss}
end

---@param tick GameTick
---@return table? balance  nil until the first sample
local function measure_balance(tick)
  local stats = storage.grid_stats
  if not stats then return nil end
  local samples = stats.samples
  samples[#samples + 1] = sample_balance(tick)
  while #samples > STATS_SAMPLES do table.remove(samples, 1) end
  local machines, line, transformer = 0, 0, 0
  for _, sample in ipairs(samples) do
    machines = machines + sample.machines
    line = line + sample.line
    transformer = transformer + sample.transformer
  end
  local n = #samples
  machines, line, transformer = machines / n, line / n, transformer / n
  return {
    generated = machines + line + transformer,
    delivered = machines,
    lost = line + transformer,
    line = line,
    transformer = transformer,
  }
end

local function percent_of(part, whole)
  if whole <= 0 then return "0.0" end
  return string.format("%.1f", part / whole * 100)
end

local WORST_ROUTES = 5

---@param player LuaPlayer
function destroy_panel(player)
  -- gui.left: where older versions put it
  for _, root in pairs({player.gui.screen, player.gui.left}) do
    local panel = root[PANEL_NAME]
    if panel then panel.destroy() end
  end
end

-- Remembers where a player dragged the panel
---@param element LuaGuiElement
---@param player_index uint
function grid_diagram_on_moved(element, player_index)
  if element.name == PANEL_NAME then
    storage.grid_panel_location = storage.grid_panel_location or {}
    storage.grid_panel_location[player_index] = element.location
  end
end

---@param player LuaPlayer
---@param balance table?
---@param worst table[]  routes with the most power lost, worst first
local function update_panel(player, balance, worst)
  local frame = player.gui.screen[PANEL_NAME]
  if not frame then
    frame = player.gui.screen.add{type = "frame", name = PANEL_NAME, direction = "vertical"}
    -- Title bar: the frame is dragged by it
    local titlebar = frame.add{type = "flow", direction = "horizontal"}
    titlebar.drag_target = frame
    titlebar.add{type = "label", caption = {"line-loss-grid.panel-title"}, style = "frame_title", ignored_by_interaction = true}
    local handle = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
    handle.style.horizontally_stretchable = true
    handle.style.height = 24
    handle.style.minimal_width = 24
    frame.add{type = "flow", name = "content", direction = "vertical"}
    -- Flush with the left edge, a quarter of the way down, unless the player
    -- moved it before
    local saved = storage.grid_panel_location and storage.grid_panel_location[player.index]
    frame.location = saved or {x = 0, y = math.floor(player.display_resolution.height * 0.25)}
  end
  local panel = frame.content
  panel.clear()
  if not balance then
    panel.add{type = "label", caption = {"line-loss-grid.measuring"}}
    return
  end
  local format = shared.format_energy_number
  local g = balance.generated
  panel.add{type = "label", caption = {"line-loss-grid.generated", format(g)}}
  panel.add{type = "label", caption = {"line-loss-grid.delivered", format(balance.delivered), percent_of(balance.delivered, g)}}
  panel.add{type = "label", caption = {"line-loss-grid.lost", format(balance.lost), percent_of(balance.lost, g)}}
  panel.add{type = "label", caption = {"line-loss-grid.lost-transformers", format(balance.transformer), percent_of(balance.transformer, g)}}
  panel.add{type = "label", caption = {"line-loss-grid.lost-lines", format(balance.line), percent_of(balance.line, g)}}
  if #worst == 0 then return end
  panel.add{type = "line", direction = "horizontal"}
  panel.add{type = "label", caption = {"line-loss-grid.worst-title"}, style = "caption_label"}
  for i, route in ipairs(worst) do
    local row = panel.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "center"
    row.add{
      type = "button",
      caption = {"line-loss-grid.show"},
      tooltip = {"line-loss-grid.show-tooltip"},
      tags = {line_loss_goto = true, x = route.x, y = route.y, surface = route.surface},
    }
    row.add{type = "label", caption = {"line-loss-grid.worst-route", i,
      format(route.lost), string.format("%.1f", route.loss * 100), string.format("%d", math.floor(route.d + 0.5))},
      tooltip = {"line-loss-grid.worst-route-tooltip"}}
  end
end

-- "Show" button: open the map at the route's midpoint
---@param element LuaGuiElement
---@param player LuaPlayer
function grid_diagram_on_click(element, player)
  local tags = element.tags
  if not (tags and tags.line_loss_goto and player) then return end
  local surface = game.get_surface(tags.surface)
  if not surface then return end
  local position = {x = tags.x, y = tags.y}
  local ok = pcall(function()
    player.set_controller{type = defines.controllers.remote, position = position, surface = surface}
  end)
  if ok then
    pcall(function() player.zoom = 0.25 end)
  else
    -- Fallback: a clickable map pin in chat
    player.print({"line-loss-grid.route-at", string.format("[gps=%d,%d,%s]", tags.x, tags.y, surface.name)})
  end
end

---@return uint[] players, string key  players with the diagram on, and a key to detect changes
-- Players with the diagram on, and those of them who also want idle (grey)
-- routes and diamonds (per-player setting, off by default)
local function viewers()
  local list, idle, parts = {}, {}, {}
  for _, player in pairs(game.connected_players) do
    if player.is_shortcut_toggled(SHORTCUT) then
      list[#list + 1] = player.index
      local setting = player.mod_settings["line-loss-show-idle-routes"]
      local show_idle = setting and setting.value
      if show_idle then idle[#idle + 1] = player.index end
      parts[#parts + 1] = player.index .. (show_idle and "i" or "")
    end
  end
  return list, table.concat(parts, ","), idle
end

local function band_for(power, loss)
  if power <= 0 then return "idle" end
  if loss >= 0.5 then return "over" end
  if loss >= 0.1 then return "near" end
  return "ok"
end

-- Logarithmic, +3 px per factor of 10 in power:
-- 10 kW -> 2, 100 kW -> 5, 1 MW -> 8, 10 MW -> 11, 100 MW -> 14, 1 GW -> 17, capped at 20
local function width_for(power)
  if power ~= power then power = 0 end  -- NaN would crash line.width
  if power <= 10000 then return 2 end
  local w = 2 + 3 * math.log(power / 10000, 10)
  if w > 20 then w = 20 end
  return math.floor(w + 0.5)  -- whole steps, so tiny changes do not redraw
end

local function midpoint(a, b)
  return {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2}
end

-- Flips the shortcut for a player and redraws straight away rather than
-- waiting for the next 60-tick update.
---@param player LuaPlayer
---@param tick GameTick
function toggle_grid_diagram(player, tick)
  player.set_shortcut_toggled(SHORTCUT, not player.is_shortcut_toggled(SHORTCUT))
  update_grid_diagram(tick, true)
end

---@param tick GameTick
---@param force boolean?  update now regardless of the interval
function update_grid_diagram(tick, force)
  if not force and tick % UPDATE_INTERVAL ~= 0 then return end
  local players, players_key, idle_players = viewers()
  if #players == 0 or not storage.settings.enabled then
    grid_diagram_clear()
    return
  end

  local state = storage.grid_diagram
  if not state then
    state = {routes = {}, players_key = players_key}
    storage.grid_diagram = state
  end

  -- Energy balance panel
  if not storage.grid_stats then
    storage.grid_stats = {samples = {}}
  end
  -- Sample once per update interval; a forced redraw only reuses the last one
  local balance = storage.grid_stats.last
  if not force or not balance then
    balance = measure_balance(tick)
    storage.grid_stats.last = balance
  end
  local players_changed = state.players_key ~= players_key
  state.players_key = players_key

  local transformers = storage.transformers
  local seen = {}
  local worst = {}
  local receivers = {}  -- unit_number -> entity of every transformer fed by a route

  for source_unit, source in pairs(transformers) do
    local source_entity = source.transformer
    local load_total = source.line_load_total or 0
    if source_entity and source_entity.valid and source.line_sinks then
      for _, sink in pairs(source.line_sinks) do
        local sink_parts = transformers[sink.unit]
        local sink_entity = sink_parts and sink_parts.transformer
        if sink_entity and sink_entity.valid and sink_entity.surface.index == source_entity.surface.index then
          local key = source_unit .. ">" .. sink.unit
          seen[key] = true
          receivers[sink.unit] = sink_entity

          -- Proportional sharing: this route carries the source's delivered
          -- power times the sink's share of the network's load
          local power = 0
          local flows = storage.settings.closeness and source.line_flows
          if flows then
            -- Closeness-weighted flows (opt-in): power assigned to this consumer
            power = flows[sink.unit] or 0
          elseif load_total > 0 then
            power = (source.p_deliv or 0) * (sink_parts.p_draw or 0) / load_total
          end
          local loss = get_route_line_loss(sink.d)
          local band = band_for(power, loss)
          -- Power that left the source for this route but was lost on it
          -- (power is what arrives: arrives = sent * (1 - loss))
          local lost = loss < 1 and power * loss / (1 - loss) or 0
          if lost > 0 then
            local from, to = source_entity.position, sink_entity.position
            worst[#worst + 1] = {
              lost = lost, loss = loss, d = sink.d, unit = key,
              x = (from.x + to.x) / 2, y = (from.y + to.y) / 2,
              surface = source_entity.surface.index,
            }
          end
          local width = width_for(power)
          local text = shared.format_energy_number(power) .. " · " .. string.format("%.1f", loss * 100) .. "% LL"

          local route = state.routes[key]
          if route and not (rendering.get_object_by_id(route.line) or {}).valid then
            destroy_route(route)
            route = nil
          end
          -- Idle routes are drawn only for players who asked for them
          local idle = band == "idle"
          local route_players = idle and idle_players or players
          if #route_players == 0 then
            if route then destroy_route(route) end
            state.routes[key] = nil
            route = false
          end

          if route == false then
            -- not drawn for anyone
          elseif not route then
            local from, to = source_entity.position, sink_entity.position
            route = {
              band = band, width = width, text = text,
              line = rendering.draw_line{
                color = COLOURS[band], width = width,
                from = source_entity, to = sink_entity,
                surface = source_entity.surface, players = route_players,
                render_mode = "chart",
              }.id,
              label = rendering.draw_text{
                text = text, color = COLOURS[band], scale = 6,
                target = midpoint(from, to),
                surface = source_entity.surface, players = route_players,
                alignment = "center", vertical_alignment = "middle",
                render_mode = "chart",
              }.id,
            }
            state.routes[key] = route
          else
            local line = rendering.get_object_by_id(route.line)
            local label = rendering.get_object_by_id(route.label)
            local idle_changed = (route.band == "idle") ~= idle
            if route.band ~= band then
              for _, object in pairs({line, label}) do
                if object and object.valid then object.color = COLOURS[band] end
              end
              route.band = band
            end
            if idle_changed and not players_changed then
              for _, object in pairs({line, label}) do
                if object and object.valid then object.players = route_players end
              end
            end
            if route.width ~= width and line and line.valid then
              line.width = width
              route.width = width
            end
            if route.text ~= text and label and label.valid then
              label.text = text
              route.text = text
            end
            if players_changed then
              for _, object in pairs({line, label}) do
                if object and object.valid then object.players = route_players end
              end
            end
          end
        end
      end
    end
  end

  -- Routes that no longer exist (transformer removed, rewired)
  for key, route in pairs(state.routes) do
    if not seen[key] then
      destroy_route(route)
      state.routes[key] = nil
    end
  end

  -- One diamond per receiving transformer, coloured by the line loss of all
  -- the power arriving at it (power-weighted over its feeders)
  state.diamonds = state.diamonds or {}
  for unit, entity in pairs(receivers) do
    local loss = get_upstream_line_loss(unit) or 0
    local receiver_parts = transformers[unit]
    local band = band_for(receiver_parts and receiver_parts.p_draw or 0, loss)
    local diamond = state.diamonds[unit]
    local object = diamond and rendering.get_object_by_id(diamond.id)
    local diamond_players = band == "idle" and idle_players or players
    if #diamond_players == 0 then
      if object and object.valid then object.destroy() end
      state.diamonds[unit] = nil
    elseif not (object and object.valid) then
      local s = DIAMOND_SIZE
      -- triangle strip: top, left, right, bottom
      object = rendering.draw_polygon{
        color = COLOURS[band],
        vertices = {{x = 0, y = -s}, {x = -s, y = 0}, {x = s, y = 0}, {x = 0, y = s}},
        target = entity,
        surface = entity.surface, players = diamond_players,
        render_mode = "chart",
      }
      state.diamonds[unit] = {id = object.id, band = band}
    else
      local idle_changed = (diamond.band == "idle") ~= (band == "idle")
      if diamond.band ~= band then
        object.color = COLOURS[band]
        diamond.band = band
      end
      if players_changed or idle_changed then object.players = diamond_players end
    end
  end
  for unit, diamond in pairs(state.diamonds) do
    if not receivers[unit] then
      destroy(diamond.id)
      state.diamonds[unit] = nil
    end
  end

  -- Generators -> transformer (generator networks): lost on the way in
  for unit, parts in pairs(transformers) do
    local entity = parts.transformer
    if (parts.gen_burn or 0) > 0 and entity and entity.valid then
      local p = entity.position
      local gen_loss, gen_d = get_generator_loss(parts, tick)
      worst[#worst + 1] = {
        lost = parts.gen_burn, loss = gen_loss or 0, d = gen_d or 0, unit = "gen>" .. unit,
        x = p.x, y = p.y, surface = entity.surface.index,
      }
    end
  end

  -- Energy balance and worst routes panel
  table.sort(worst, function(a, b)
    if a.lost ~= b.lost then return a.lost > b.lost end
    return a.unit < b.unit
  end)
  for i = #worst, WORST_ROUTES + 1, -1 do worst[i] = nil end
  local viewing = {}
  for _, index in pairs(players) do viewing[index] = true end
  for _, player in pairs(game.connected_players) do
    if viewing[player.index] then
      update_panel(player, balance, worst)
    else
      destroy_panel(player)
    end
  end
end
