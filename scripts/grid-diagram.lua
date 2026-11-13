-- With the losses view on (line-loading.lua): a diamond on each receiving
-- transformer, coloured by its total upstream loss (line loss of every
-- segment plus every transformer's losses between the generators and it):
-- green < 10%, yellow < 50%, red above. And the grid power panel (left edge,
-- draggable), for one network: the downstream network of the transformer the
-- player last hovered or opened. Power supplied to it, reaching machines,
-- passed to downstream transformers and lost on it over the last 5 s, and the
-- wires on it losing the most power, each with a button that shows it on the
-- map. Nothing is computed while nobody has the view on.

local UPDATE_INTERVAL = 60
-- Energy-balance window: one sample per update, averaged over this many
local STATS_SAMPLES = 5
local PANEL_NAME = "line-loss-grid-panel"
local DIAMOND_SIZE = 5  -- tiles from centre to tip; marks a receiving transformer
local SHORTCUT = "line-loss-toggle-losses"

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
  storage.grid_panel_target = nil
  for _, player in pairs(game.players) do
    destroy_panel(player)
  end
  local state = storage.grid_diagram
  if not state then return end
  for _, route in pairs(state.routes or {}) do
    destroy_route(route)
  end
  for _, diamond in pairs(state.diamonds or {}) do
    destroy(diamond.id)
  end
  storage.grid_diagram = nil
end

-- Energy balance -------------------------------------------------------------
-- Sources: each transformer feeding the network (what it outputs into it: its
-- delivery plus the line loss it pays here) and the generators on it.
-- Consumption (rows with nothing hidden, except line loss): machines (anything that is not a transformer or a loss
-- consumer, accumulators charging included), downstream transformers' inputs,
-- their "Transformer losses" consumers (inefficiency and core loss) and the
-- "Line loss" consumers (everything lost on this network's wires).

---@param pole LuaEntity  a pole of the network
---@param tick GameTick
local function sample_network(pole, tick)
  local loads = get_network_loads(pole, tick)
  local net = pole.electric_network_id
  local feeders = {}
  for unit, parts in pairs(storage.transformers) do
    local out = parts.pole_out
    if out and out.valid and out.electric_network_id == net then
      feeders[unit] = (parts.p_deliv or 0) + (parts.line_burn or 0)
    end
  end
  return {machines = loads.machines, line = loads.line, ineff = loads.ineff, onward = loads.transformers,
    generated = loads.generated or 0, feeders = feeders}
end

-- Averaged over the last STATS_SAMPLES samples of a network
---@param stats table  {samples}
local function average(stats)
  local acc = {machines = 0, line = 0, ineff = 0, onward = 0, generated = 0}
  local feeders = {}
  local samples = stats.samples
  for _, sample in ipairs(samples) do
    for k in pairs(acc) do acc[k] = acc[k] + (sample[k] or 0) end
    for unit, w in pairs(sample.feeders or {}) do feeders[unit] = (feeders[unit] or 0) + w end
  end
  local n = math.max(#samples, 1)
  for k in pairs(acc) do acc[k] = acc[k] / n end
  for unit in pairs(feeders) do feeders[unit] = feeders[unit] / n end
  acc.feeders = feeders
  acc.consumed = acc.machines + acc.line + acc.ineff + acc.onward
  acc.sources = acc.generated
  for _, w in pairs(feeders) do acc.sources = acc.sources + w end
  return acc
end

local function percent_of(part, whole)
  if whole <= 0 then return "0.0" end
  return string.format("%.1f", part / whole * 100)
end

local WORST_WIRES = 5

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

local function gps(entity)
  local p = entity.position
  return string.format("[gps=%d,%d,%s]", math.floor(p.x), math.floor(p.y), entity.surface.name)
end

-- Transmission or distribution, read from the hidden output pole or a pole
-- wired to it; also returns the pole it was read from
local function network_kind(parts)
  local out = parts and parts.pole_out
  if not (out and out.valid) then return nil end
  local kind = kirchhoff_network_kind(out.unit_number)
  if kind then return kind, out.unit_number end
  for _, pole in pairs(out.neighbours and out.neighbours.copper or {}) do
    if pole.valid then
      kind = kirchhoff_network_kind(pole.unit_number)
      if kind then return kind, pole.unit_number end
    end
  end
  return nil
end

---@param player LuaPlayer
---@param target LuaEntity?  the transformer whose downstream network is shown
---@param balance table?
---@param worst table[]  wires of that network losing the most power, worst first
local function update_panel(player, target, balance, worst)
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
  if not target then
    panel.add{type = "label", caption = {"line-loss-grid.pick"}}
    return
  end
  local kind, unit = network_kind(storage.transformers[target.unit_number])
  panel.add{type = "label", caption = {"line-loss-network." .. (kind or "unknown")}, style = "caption_label",
    tooltip = network_kind_tooltip(kind, unit)}
  panel.add{type = "label", caption = {"line-loss-grid.network", target.localised_name, gps(target)}}
  if not balance then
    panel.add{type = "label", caption = {"line-loss-grid.measuring"}}
    return
  end
  local format = ratings.format_power
  -- Sources: transformers feeding the network (largest first), then generators
  local total = balance.sources
  panel.add{type = "label", caption = {"line-loss-grid.sources", format(total)}, style = "caption_label"}
  local units = {}
  for unit in pairs(balance.feeders) do units[#units + 1] = unit end
  table.sort(units, function(a, b)
    local wa, wb = balance.feeders[a], balance.feeders[b]
    if wa ~= wb then return wa > wb end
    return a < b
  end)
  for _, unit in ipairs(units) do
    local parts = storage.transformers[unit]
    local entity = parts and parts.transformer
    if entity and entity.valid then
      local w = balance.feeders[unit]
      local key = unit == target.unit_number and "line-loss-grid.source-hovered" or "line-loss-grid.source"
      panel.add{type = "label", caption = {key, entity.localised_name, gps(entity), format(w), percent_of(w, total)}}
    end
  end
  if balance.generated > 0 then
    panel.add{type = "label", caption = {"line-loss-grid.generators", format(balance.generated),
      percent_of(balance.generated, total)}}
  end
  -- Consumption
  local used = balance.consumed
  panel.add{type = "label", caption = {"line-loss-grid.consumption", format(used)}, style = "caption_label"}
  local function part(key, w, always)
    if always or w > 0 then
      panel.add{type = "label", caption = {"line-loss-grid." .. key, format(w), percent_of(w, used)}}
    end
  end
  part("machines", balance.machines)
  part("onward", balance.onward)
  part("transformer-losses", balance.ineff)
  part("line-loss", balance.line, true)
  if #worst == 0 then return end
  panel.add{type = "line", direction = "horizontal"}
  panel.add{type = "label", caption = {"line-loss-grid.worst-title"}, style = "caption_label"}
  for i, wire in ipairs(worst) do
    local row = panel.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "center"
    row.add{
      type = "button",
      caption = {"line-loss-grid.show"},
      tags = {line_loss_goto = true, x = wire.x, y = wire.y, surface = wire.surface, ends = wire.ends},
    }
    row.add{type = "label", caption = {"line-loss-grid.worst-wire", i, format(wire.lost), format(wire.w),
      percent_of(wire.lost, wire.w)}}
  end
end

local HIGHLIGHT_TICKS = 600  -- how long the circles of a shown route stay
local HIGHLIGHT_COLOUR = {r = 1, g = 0, b = 0}

-- Red circles around a wire's two poles, for this player only: one drawn in
-- the world, one on the map view. The previous circles go.
local function highlight_route(player, surface, ends)
  storage.route_highlights = storage.route_highlights or {}
  for _, id in pairs(storage.route_highlights[player.index] or {}) do destroy(id) end
  local ids = {}
  for _, p in pairs(ends or {}) do
    local position = {x = p[1], y = p[2]}
    for _, mode in pairs({"game", "chart"}) do
      ids[#ids + 1] = rendering.draw_circle{
        color = HIGHLIGHT_COLOUR,
        radius = mode == "game" and 3 or 6,
        width = mode == "game" and 4 or 6,
        filled = false,
        target = position,
        surface = surface,
        players = {player},
        time_to_live = HIGHLIGHT_TICKS,
        render_mode = mode,
      }.id
    end
  end
  storage.route_highlights[player.index] = ids
end

-- "Show" button: open the map at the wire's midpoint and circle its poles
---@param element LuaGuiElement
---@param player LuaPlayer
function grid_diagram_on_click(element, player)
  local tags = element.tags
  if not (tags and tags.line_loss_goto and player) then return end
  local surface = game.get_surface(tags.surface)
  if not surface then return end
  local position = {x = tags.x, y = tags.y}
  highlight_route(player, surface, tags.ends)
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

---@return uint[] players, string key  players with the losses view on, and a key to detect changes
local function viewers()
  local list = {}
  for _, player in pairs(game.connected_players) do
    if player.is_shortcut_toggled(SHORTCUT) then list[#list + 1] = player.index end
  end
  return list, table.concat(list, ",")
end

local function band_for(power, loss)
  if power <= 0 then return "idle" end
  if loss >= 0.5 then return "over" end
  if loss >= 0.1 then return "near" end
  return "ok"
end

-- The panel's transformer for a player: the one hovered, or the one opened
local function pick_target(player)
  local entity = hovered_transformer(player)
  if not entity then
    local opened = player.opened
    if opened and player.opened_gui_type == defines.gui_type.entity and opened.valid
        and TRANSFORMER_NAMES[opened.name] then
      entity = opened
    end
  end
  return entity and entity.unit_number
end

---@param tick GameTick
---@param force boolean?  update now regardless of the interval
function update_grid_diagram(tick, force)
  -- a viewer pointing at another transformer: update now
  if force or storage.grid_diagram then
    local targets = storage.grid_panel_target or {}
    for _, player in pairs(game.connected_players) do
      if player.is_shortcut_toggled(SHORTCUT) then
        local unit = pick_target(player)
        if unit and unit ~= targets[player.index] then
          targets[player.index] = unit
          storage.grid_panel_target = targets
          force = true
        end
      end
    end
  end
  if not force and tick % UPDATE_INTERVAL ~= 0 then return end
  local players, players_key = viewers()
  if #players == 0 or not storage.settings.enabled then
    grid_diagram_clear()
    return
  end

  local state = storage.grid_diagram
  if not state then
    state = {players_key = players_key}
    storage.grid_diagram = state
  end
  -- route lines of the grid diagram (before 0.2.0)
  for key, route in pairs(state.routes or {}) do destroy_route(route) end
  state.routes = nil

  -- Each viewer's network: the downstream network of the transformer last
  -- hovered or opened; sampled once per update interval (a forced redraw
  -- reuses the last sample unless the network is new)
  local stats = storage.grid_stats
  if not stats or not stats.by_net then
    stats = {by_net = {}}
    storage.grid_stats = stats
  end
  local targets = storage.grid_panel_target or {}
  local shown = {}  -- player index -> {entity, net}
  local wanted = {}
  for _, index in pairs(players) do
    local parts = targets[index] and storage.transformers[targets[index]]
    local pole = parts and parts.pole_out
    local net = pole and pole.valid and pole.electric_network_id
    if net and parts.transformer and parts.transformer.valid then
      shown[index] = {entity = parts.transformer, net = net}
      if not wanted[net] then
        wanted[net] = true
        local entry = stats.by_net[net]
        if not entry then
          entry = {samples = {}}
          stats.by_net[net] = entry
        end
        if not force or #entry.samples == 0 then
          entry.samples[#entry.samples + 1] = sample_network(pole, tick)
          while #entry.samples > STATS_SAMPLES do table.remove(entry.samples, 1) end
        end
      end
    end
  end
  for net in pairs(stats.by_net) do
    if not wanted[net] then stats.by_net[net] = nil end
  end
  local players_changed = state.players_key ~= players_key
  state.players_key = players_key

  local transformers = storage.transformers
  local worst = {}
  local receivers = {}  -- unit_number -> entity of every transformer fed by a route

  -- Each route: the power a feeder sends to a transformer (its share of the
  -- flows) and the loss on the way
  for sink_unit, sink_parts in pairs(transformers) do
    local sink_entity = sink_parts.transformer
    local feeders = sink_entity and sink_entity.valid and get_assigned_feeders(sink_unit)
    if feeders then
      receivers[sink_unit] = sink_entity
    end
  end

  -- One diamond per receiving transformer, coloured by its total
  -- upstream loss: everything lost between the generators and it (the same
  -- value the hover shows by default).
  state.diamonds = state.diamonds or {}
  for unit, entity in pairs(receivers) do
    local loss = get_cumulative_upstream_loss(unit) or 0
    local receiver_parts = transformers[unit]
    local band = band_for(receiver_parts and receiver_parts.p_draw or 0, loss)
    local diamond = state.diamonds[unit]
    local object = diamond and rendering.get_object_by_id(diamond.id)
    local diamond_players = players
    if band == "idle" then
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
      if diamond.band ~= band then
        object.color = COLOURS[band]
        diamond.band = band
      end
      if players_changed then object.players = diamond_players end
    end
  end
  for unit, diamond in pairs(state.diamonds) do
    if not receivers[unit] then
      destroy(diamond.id)
      state.diamonds[unit] = nil
    end
  end

  -- Wires losing the most power (from the last refresh), worst first; each
  -- viewer's list keeps the first ones on its network
  local loads = kirchhoff_wire_loads and kirchhoff_wire_loads() or {}
  for _, e in pairs(loads) do
    if (e.lost or 0) > 0 then worst[#worst + 1] = e end
  end
  table.sort(worst, function(a, b)
    if a.lost ~= b.lost then return a.lost > b.lost end
    if a.a ~= b.a then return a.a < b.a end
    return a.b < b.b
  end)
  local graph = storage.wire_graph or {}
  local function wire_entry(e)
    local na, nb = graph[e.a], graph[e.b]
    local ea, eb = na and na.e, nb and nb.e
    if not (ea and ea.valid and eb and eb.valid and ea.surface == eb.surface) then return nil end
    local pa, pb = ea.position, eb.position
    return {net = ea.electric_network_id, lost = e.lost, w = e.w, x = (pa.x + pb.x) / 2, y = (pa.y + pb.y) / 2,
      surface = ea.surface.index, ends = {{pa.x, pa.y}, {pb.x, pb.y}}}
  end
  local viewing = {}
  for _, index in pairs(players) do viewing[index] = true end
  for _, player in pairs(game.connected_players) do
    if viewing[player.index] then
      local s = shown[player.index]
      local mine = {}
      if s then
        local checked = 0
        for _, e in ipairs(worst) do
          if #mine >= WORST_WIRES or checked > 2000 then break end
          checked = checked + 1
          local entry = wire_entry(e)
          if entry and entry.net == s.net then mine[#mine + 1] = entry end
        end
      end
      update_panel(player, s and s.entity, s and average(stats.by_net[s.net]), mine)
    else
      destroy_panel(player)
    end
  end
end
