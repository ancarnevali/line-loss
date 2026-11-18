-- Line loading: map views of the power each wire carries, from the flows
-- solved in kirchhoff.lua.
--
-- Three views, one shortcut each (a player sees one at a time):
--   power:  width and colour by the power on the wire, relative to the busiest
--   rated:  width and colour by the power as a share of the wire's rating
--           (the weaker of its two poles): green, yellow at 60%, red at 80%
--   losses: width and colour by the power lost on the wire, relative to the
--           wire losing most on its surface; diamonds and the power panel from
--           grid-diagram.lua
-- Feeders panel (any view): an arrow above the tracked transformer and an icon
-- at each of its sources
-- as the last refresh assigned it (flows on transmission, nearest sources on
-- distribution), labelled at each source with its share and the line loss. Power
-- Overload's map colouring is hidden while a view is on. Mixed wires (a
-- transmission pole straight to a distribution pole) are dashed. Idle wires are thin
-- and grey. A pole's local load is the most power on any of its wires.
-- Redrawn every REFRESH_INTERVAL ticks; only wires whose drawing changed are
-- touched; new drawings DRAWS_PER_TICK a tick.
--
-- Pole overload by local load: with Power Overload's own check set to
-- "Nothing", poles are checked against their local load at Power Overload's
-- rhythm (fuses 10x as often), with the same consequences, and the pole hover
-- shows the local load in place of Power Overload's network figure (hidden).

local ratings = require("__line-loss__/scripts/ratings")

local MODES = {
  power = "line-loss-toggle-line-loading",
  rated = "line-loss-toggle-line-loading-rated",
  losses = "line-loss-toggle-losses",
  networks = "line-loss-toggle-networks",
}
-- Networks view, drawn like Power Overload's network colouring (lines width 8,
-- a dot on every pole): transmission networks white; in distribution networks
-- each pole in the colour of the transformer feeding it, Power Overload's
-- default colour for that transformer (its palette by unit number).
-- With the panel's "Network types" box ticked the player sees the "types"
-- drawing instead: transmission networks white, distribution networks blue.
local WHITE = {r = 1, g = 1, b = 1}
local BLUE = {r = 0.25, g = 0.55, b = 1}
-- drawings: one per shortcut, plus "types", drawn for the networks view
local DRAWINGS = {"power", "rated", "losses", "networks", "types"}
local function transformer_colour(unit)
  local palette = shared and shared.network_color_palette
  if not palette or #palette == 0 then return nil end
  local entry = palette[(unit % #palette) + 1]
  return {r = entry.r, g = entry.g, b = entry.b}
end
local NETWORK_WIDTH = 8
local REFRESH_INTERVAL = 300
local HOVER_INTERVAL = 10
local MIN_W = 1000          -- below 1 kW a wire counts as idle
local DRAWS_PER_TICK = 400  -- so switching a view on does not stall a tick
local STEPS = 20            -- drawing steps (5% of the busiest wire, or of the rating)

local IDLE = {r = 0.55, g = 0.55, b = 0.55, a = 0.6}
local GREEN, YELLOW, RED = {0.15, 0.80, 0.20}, {1.00, 0.85, 0.10}, {0.90, 0.12, 0.10}

local function mix(a, b, t)
  t = math.max(0, math.min(1, t))
  return {r = a[1] + (b[1] - a[1]) * t, g = a[2] + (b[2] - a[2]) * t, b = a[3] + (b[3] - a[3]) * t, a = 1}
end

-- Colour and width of a drawing step
local function colour_key(c)
  return string.format("%.3f,%.3f,%.3f", c.r or c[1], c.g or c[2], c.b or c[3])
end

local function look(mode, step)
  if mode == "networks" or mode == "types" then
    if type(step) ~= "string" then return IDLE, 2 end
    local r, g, b = step:match("^([%d.]+),([%d.]+),([%d.]+)$")
    return {r = tonumber(r), g = tonumber(g), b = tonumber(b), a = 0.9}, NETWORK_WIDTH
  end
  if step == 0 then return IDLE, 2 end
  local f = step / STEPS
  if mode == "power" or mode == "losses" then
    -- green (little) to red (the busiest wire, or the one losing most)
    local colour = f < 0.5 and mix(GREEN, YELLOW, f / 0.5) or mix(YELLOW, RED, (f - 0.5) / 0.5)
    return colour, 4 + 16 * f
  end
  -- share of the rating: green, yellow at 60%, red at 80% and over
  local colour = f < 0.6 and mix(GREEN, YELLOW, f / 0.6) or mix(YELLOW, RED, (f - 0.6) / 0.2)
  return colour, 4 + 16 * math.min(1, f)
end

local function state()
  local st = storage.line_loading
  if not st or not st.modes then
    -- (0.2.0 development saves had one view)
    if st and st.wires then
      for _, wire in pairs(st.wires) do
        if wire.obj and wire.obj.valid then wire.obj.destroy() end
      end
    end
    st = {modes = {}, pole_load = {}, hover = {}}
    storage.line_loading = st
  end
  for _, mode in ipairs(DRAWINGS) do st.modes[mode] = st.modes[mode] or {wires = {}} end
  st.highlight = st.highlight or {}
  return st
end

local function viewers(mode)
  local list = {}
  local types = storage.network_types_on or {}
  for _, player in pairs(game.connected_players) do
    if mode == "networks" or mode == "types" then
      if player.is_shortcut_toggled(MODES.networks) and (types[player.index] == true) == (mode == "types") then
        list[#list + 1] = player.index
      end
    elseif player.is_shortcut_toggled(MODES[mode]) then
      list[#list + 1] = player.index
    end
  end
  return list
end

-- Players with any view on
local function any_viewers()
  local list = {}
  for mode in pairs(MODES) do
    for _, index in ipairs(viewers(mode)) do list[#list + 1] = index end
  end
  table.sort(list)
  return list
end

-- Power Overload's map colouring (its chart-mode lines and circles), hidden
-- for players with a view on by narrowing each object's player list, and given
-- back when nobody has one on. Its texts are left alone. Objects already
-- handled for the current set of players are skipped after reading their id.
local function apply_po_overlay()
  local st = storage.po_overlay or {hidden = {}, handled = {}}
  storage.po_overlay = st
  local hiders, others = {}, {}
  for _, player in pairs(game.connected_players) do
    local on = false
    for _, shortcut in pairs(MODES) do
      if player.is_shortcut_toggled(shortcut) then on = true end
    end
    if on then hiders[#hiders + 1] = player.index else others[#others + 1] = player.index end
  end
  local key = table.concat(hiders, ",") .. "|" .. table.concat(others, ",")
  if #hiders == 0 and next(st.hidden) == nil then
    st.key = key
    return
  end
  if st.key ~= key then
    st.key, st.handled = key, {}
  end
  local ok, objects = pcall(rendering.get_all_objects, "PowerOverload")
  if not ok or not objects then return end
  local function report(err)
    if not st.reported then
      st.reported = true
      game.print({"", "[Line loss] Power Overload's map colours could not be hidden: ", tostring(err)})
    end
  end
  local handled = st.handled
  for _, object in pairs(objects) do
    local id = object.id
    if not handled[id] then
      handled[id] = true
      if object.valid and object.render_mode == "chart" and (object.type == "line" or object.type == "circle") then
        if #hiders == 0 then
          if st.hidden[id] then
            local done, err = pcall(function()
              object.visible = true
              object.players = {}
            end)
            if not done then report(err) end
          end
        else
          local done, err = pcall(function()
            if #others == 0 then
              object.visible = false
            else
              object.visible = true
              object.players = others
            end
          end)
          if done then st.hidden[id] = true else report(err) end
        end
      end
    end
  end
  if #hiders == 0 then st.hidden, st.handled = {}, {} end
end

local function wire_key(a, b)
  if a < b then return a .. ":" .. b end
  return b .. ":" .. a
end

local function entity_of(unit)
  local node = storage.wire_graph and storage.wire_graph[unit]
  local e = node and node.e
  return e and e.valid and e or nil
end

-- Power on every wire (W) and power lost on it, from the last solve
local function compute()
  return kirchhoff_wire_loads() or {}
end

-- Every wire between poles the searches have met, for the idle drawing
local function all_wires()
  local wires = {}
  for unit, node in pairs(storage.wire_graph or {}) do
    local adj = node.adj
    for x = 1, #adj, 3 do
      local other = adj[x]
      if unit < other and storage.wire_graph[other] then
        wires[wire_key(unit, other)] = {a = unit, b = other}
      end
    end
  end
  return wires
end

-- A wire's rating: the weaker of its two poles (a transformer's hidden pole
-- has none and does not count)
local function wire_rating(a, b)
  local ea, eb = entity_of(a), entity_of(b)
  local ra = ea and string.sub(ea.name, 1, 10) ~= "po-hidden-" and line_loss_pole_rating(ea)
  local rb = eb and string.sub(eb.name, 1, 10) ~= "po-hidden-" and line_loss_pole_rating(eb)
  if ra and rb then return math.min(ra, rb) end
  return ra or rb or nil
end

local function clear_mode(view)
  for _, set in pairs({view.wires, view.dots or {}, view.labels or {}}) do
    for _, item in pairs(set) do
      if item.obj and item.obj.valid then item.obj.destroy() end
    end
  end
  view.wires, view.dots, view.labels, view.queue, view.queue_pos = {}, nil, nil, nil, nil
end

local function draw_mode(mode, view, players, loads, wanted, vmax, tick)
  local players_key = table.concat(players, ",")
  local seen, queue = {}, {}
  local networks = mode == "networks" or mode == "types"
  local pole_step = networks and {} or nil
  -- networks view: the colour of a pole; poles fed by generators are not drawn
  local function pole_colour(unit)
    local kind = kirchhoff_network_kind(unit)
    if kind == "transmission" then return WHITE end
    if kind == "distribution" then
      if mode == "types" then return BLUE end
      local source = kirchhoff_pole_source(unit)
      if type(source) == "number" then return transformer_colour(source) end
    end
    return nil
  end
  for key, wire in pairs(wanted) do
    local entry = loads[key]
    local w = entry and entry.w or 0
    local step = 0
    if networks then
      local ca, cb = pole_colour(wire.a), pole_colour(wire.b)
      local ka, kb = ca and colour_key(ca), cb and colour_key(cb)
      if ka then pole_step[wire.a] = ka end
      if kb then pole_step[wire.b] = kb end
      step = ka or kb or 0
    elseif w >= MIN_W then
      if mode == "power" then
        if vmax > 0 then step = math.max(1, math.floor(STEPS * w / vmax + 0.5)) end
      elseif mode == "losses" then
        local lost, lost_max = entry.lost or 0, entry.lost_max or 0
        if lost > 0 and lost_max > 0 then step = math.max(1, math.floor(STEPS * lost / lost_max + 0.5)) end
      else
        local rating = wire_rating(wire.a, wire.b)
        if rating and rating > 0 then
          step = math.max(1, math.min(STEPS + 4, math.floor(STEPS * w / rating + 0.5)))
        end
      end
    end
    local old = view.wires[key]
    if old and old.obj and old.obj.valid then
      if old.step ~= step then
        old.obj.color, old.obj.width = look(mode, step)
        old.step = step
      end
      if view.players_key ~= players_key then old.obj.players = players end
    else
      queue[#queue + 1] = {key = key, a = wire.a, b = wire.b, step = step}
    end
    seen[key] = true
  end
  for key, wire in pairs(view.wires) do
    if not seen[key] then
      if wire.obj and wire.obj.valid then wire.obj.destroy() end
      view.wires[key] = nil
    end
  end
  if networks then
    -- a dot on every pole (not the transformers' hidden poles), like Power Overload
    view.dots = view.dots or {}
    local seen_dots = {}
    local graph = storage.wire_graph or {}
    for unit, step in pairs(pole_step) do
      local node = graph[unit]
      if not (node and node.h) then
        seen_dots[unit] = true
        local old = view.dots[unit]
        if old and old.obj and old.obj.valid then
          if old.step ~= step then
            local colour = look(mode, step)
            colour.a = 0.8
            old.obj.color, old.step = colour, step
          end
          if view.players_key ~= players_key then old.obj.players = players end
        else
          queue[#queue + 1] = {dot = unit, step = step}
        end
      end
    end
    for unit, dot in pairs(view.dots) do
      if not seen_dots[unit] then
        if dot.obj and dot.obj.valid then dot.obj.destroy() end
        view.dots[unit] = nil
      end
    end
  end
  view.queue, view.queue_pos, view.players_key = queue, 1, players_key
end

local function draw_queued(mode, view, budget)
  local queue, pos = view.queue, view.queue_pos or 1
  if not queue then return end
  local players
  while budget > 0 and pos <= #queue do
    local item = queue[pos]
    pos = pos + 1
    if item.dot then
      local e = entity_of(item.dot)
      view.dots = view.dots or {}
      if e and e.valid and not view.dots[item.dot] then
        players = players or viewers(mode)
        if #players == 0 then break end
        local colour = look(mode, item.step)
        colour.a = 0.8
        view.dots[item.dot] = {step = item.step, obj = rendering.draw_circle{
          color = colour, radius = 0.8, filled = true, target = e, surface = e.surface,
          players = players, render_mode = "chart",
        }}
        budget = budget - 1
      end
    elseif not view.wires[item.key] then
      local a, b = entity_of(item.a), entity_of(item.b)
      -- (a transformer's hidden poles are also wired to its parts on Power
      -- Overload's own surface)
      if a and b and a.surface == b.surface then
        players = players or viewers(mode)
        if #players == 0 then break end
        local colour, width = look(mode, item.step)
        -- mixed wires (transmission pole straight to a distribution pole) dashed
        local dash, gap
        if (storage.settings.mixed or 1) > 1 and line_loss_mixed_wire(a.name, b.name) then dash, gap = 1.5, 1 end
        local obj = rendering.draw_line{
          color = colour, width = width, from = a, to = b, surface = a.surface,
          players = players, render_mode = "chart", dash_length = dash, gap_length = gap,
        }
        view.wires[item.key] = {obj = obj, step = item.step}
        budget = budget - 1
      end
    end
  end
  if pos > #queue then
    view.queue, view.queue_pos = nil, nil
  else
    view.queue_pos = pos
  end
end

-- Power Overload's own overload check is off
local function po_check_off()
  local setting = settings.global["power-overload-on-pole-overload"]
  return setting and setting.value == "nothing"
end

-- Poles overload on their local load (hover, checks): line losses on and
-- Power Overload's check off
local function local_overload()
  return storage.settings and storage.settings.enabled and po_check_off()
end

-- Poles to check for overload: every pole the searches have met
local function build_check_lists(st)
  local poles, fuses = {}, {}
  for unit, node in pairs(storage.wire_graph or {}) do
    if not node.h then
      if string.sub(node.n, -5) == "-fuse" then fuses[#fuses + 1] = unit else poles[#poles + 1] = unit end
    end
  end
  table.sort(poles)
  table.sort(fuses)
  st.check = {pole = poles, fuse = fuses}
end

local function redraw(tick)
  local st = state()
  local any = false
  local players = {}
  for _, mode in ipairs(DRAWINGS) do
    players[mode] = viewers(mode)
    if #players[mode] > 0 then any = true else clear_mode(st.modes[mode]) end
  end
  if not any and not local_overload() then
    st.pole_load, st.check = {}, nil
    return
  end
  local loads = compute()
  local vmax, pole_load = 0, {}
  for _, entry in pairs(loads) do
    if entry.w > vmax then vmax = entry.w end
    if entry.w > (pole_load[entry.a] or 0) then pole_load[entry.a] = entry.w end
    if entry.w > (pole_load[entry.b] or 0) then pole_load[entry.b] = entry.w end
  end
  st.pole_load = pole_load
  if local_overload() then build_check_lists(st) end
  if not any then return end
  -- Losses view: relative to the wire losing most on the same surface
  local graph = storage.wire_graph or {}
  local function surface_of(unit)
    local node = graph[unit]
    if not node then return 0 end
    if not node.si then
      local e = node.e
      node.si = e and e.valid and e.surface.index or 0
    end
    return node.si
  end
  local surface_max = {}
  for _, entry in pairs(loads) do
    local si = surface_of(entry.a)
    entry.si = si
    if (entry.lost or 0) > (surface_max[si] or 0) then surface_max[si] = entry.lost end
  end
  for _, entry in pairs(loads) do entry.lost_max = surface_max[entry.si] or 0 end
  local wanted = all_wires()
  for key, entry in pairs(loads) do
    -- wires through hidden poles (a transformer's own output or input) too
    wanted[key] = wanted[key] or {a = entry.a, b = entry.b}
  end
  for _, mode in ipairs(DRAWINGS) do
    if #players[mode] > 0 then draw_mode(mode, st.modes[mode], players[mode], loads, wanted, vmax, tick) end
  end
end

-- With overload by local load, the hovered pole shows its local load against its
-- rating, where Power Overload shows the network's load (hidden, below)
local COLOURS = {ok = {0, 1, 0}, near = {1, 1, 0}, over = {1, 0, 0}}

local function update_hover(st)
  local active = local_overload()
  for _, player in pairs(game.connected_players) do
    local index = player.index
    local pole = active and player.selected
    local shown = st.hover[index]
    local rating = pole and pole.valid and pole.type == "electric-pole" and line_loss_pole_rating(pole)
    if not rating then
      if shown then
        if shown.obj and shown.obj.valid then shown.obj.destroy() end
        st.hover[index] = nil
      end
    else
      local w = st.pole_load[pole.unit_number] or 0
      local ratio = w / rating
      local colour = ratio > 1 and COLOURS.over or ratio > 0.8 and COLOURS.near or COLOURS.ok
      local text = ratings.format_power(w) .. " / " .. ratings.format_power(rating)
      if shown and shown.obj and shown.obj.valid and shown.unit == pole.unit_number then
        if shown.text ~= text then
          shown.obj.text, shown.obj.color, shown.text = text, colour, text
        end
      else
        if shown and shown.obj and shown.obj.valid then shown.obj.destroy() end
        st.hover[index] = {
          obj = rendering.draw_text{
            text = text, surface = pole.surface,
            target = {entity = pole, offset = {x = 0, y = 0.7}},
            color = colour, scale = 1.5 * player.display_scale, alignment = "center",
            scale_with_zoom = true, players = {player},
          },
          unit = pole.unit_number, text = text,
        }
        st.hover_changed = true
      end
    end
  end
end

-- Power Overload's pole hover texts (its network figure) hidden while poles
-- load is on. Each object is looked at once.
local function hide_po_hover(st)
  local ok, objects = pcall(rendering.get_all_objects, "PowerOverload")
  if not ok or not objects then return end
  local seen = st.po_seen or {}
  local n = 0
  for _, object in pairs(objects) do
    local id = object.id
    n = n + 1
    if not seen[id] then
      seen[id] = true
      if object.valid and object.type == "text" and object.render_mode == "game" then
        local target = object.target
        local entity = target and target.entity
        if entity and entity.valid and entity.type == "electric-pole" then object.visible = false end
      end
    end
  end
  -- forget objects that are gone once the table is much bigger than the live set
  local size = 0
  for _ in pairs(seen) do size = size + 1 end
  if size > 2 * n + 100 then
    local live = {}
    for _, object in pairs(objects) do live[object.id] = seen[object.id] end
    seen = live
  end
  st.po_seen = seen
end

-- Overload: Power Overload's rhythm and consequences, on local load
local DELAY = {destroy = 300, damage = 60, fire = 600}

local function alert(pole, w)
  local force = pole.force
  if not force then return end
  for _, player in pairs(force.players) do player.add_alert(pole, defines.alert_type.entity_destroyed) end
  local log_setting = settings.global["power-overload-log-to-chat"]
  if not log_setting or log_setting.value then
    force.print({"overload-alert.alert", pole.name, math.ceil(w / 1000000)})
  end
end

local function check_overload(st, kind, delay)
  local list = st.check and st.check[kind]
  if not list or #list == 0 then return end
  local mode = storage.settings.pole_overload or "destroy"
  if kind == "fuse" then delay = delay / 10 end
  for _ = 1, math.floor(#list / delay) + 1 do
    if #list == 0 then return end
    local i = math.random(#list)
    local unit = list[i]
    local node = storage.wire_graph[unit]
    local pole = node and node.e
    if not (pole and pole.valid) then
      list[i] = list[#list]
      list[#list] = nil
    else
      local rating = line_loss_pole_rating(pole)
      local w = st.pole_load[unit] or 0
      if rating and w > rating * 1.01 then
        if mode == "destroy" then
          alert(pole, w)
          list[i] = list[#list]
          list[#list] = nil
          pole.die()
        elseif mode == "fire" and kind ~= "fuse" then
          if (w / rating + 0.01) * math.random() > 1 then
            pole.surface.create_entity{name = "fire-flame", position = pole.position}
          end
        else
          local damage = (w / rating - 0.95) * 10
          if damage > pole.health then alert(pole, w) end
          pole.damage(damage, "neutral")
        end
      end
    end
  end
end

local FEEDER_REFRESH = 300
local FEEDERS_PANEL = "line-loss-feeders"
local MAX_GEN_MARKERS = 200

local function clear_highlight(st, index)
  local shown = st.highlight[index]
  if not shown then return end
  for _, obj in pairs(shown.objs) do
    if obj.valid then obj.destroy() end
  end
  st.highlight[index] = nil
end

-- A map marker: an icon as rich text, the same size on screen at any zoom
local function marker(objs, player, entity, text, vertical, orientation)
  if not (entity and entity.valid) then return end
  objs[#objs + 1] = rendering.draw_text{
    text = text, surface = entity.surface, target = entity, color = {r = 1, g = 1, b = 1},
    scale = 1.5, scale_with_zoom = true, use_rich_text = true, orientation = orientation or 0,
    alignment = "center", vertical_alignment = vertical or "middle",
    players = {player}, render_mode = "chart",
  }
end

-- The Feeders panel: shown while a map view is on
local function feeders_panel(player)
  local frame = player.gui.screen[FEEDERS_PANEL]
  if frame then return frame end
  frame = player.gui.screen.add{type = "frame", name = FEEDERS_PANEL, direction = "vertical"}
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", caption = {"line-loss-feeders.title"}, style = "frame_title", ignored_by_interaction = true}
  local handle = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  handle.style.horizontally_stretchable = true
  handle.style.height = 24
  handle.style.minimal_width = 24
  frame.add{type = "checkbox", name = "line-loss-network-types", caption = {"line-loss-feeders.types"},
    tooltip = {"line-loss-feeders.types-tooltip"}, state = (storage.network_types_on or {})[player.index] == true,
    visible = player.is_shortcut_toggled(MODES.networks)}
  frame.add{type = "checkbox", name = "line-loss-feeders-toggle", caption = {"line-loss-feeders.show"},
    state = (storage.feeders_on or {})[player.index] == true}
  frame.add{type = "flow", name = "list", direction = "vertical"}
  frame.location = {x = 0, y = math.floor(player.display_resolution.height * 0.55)}
  return frame
end

-- One row: icon and name (or count), and a Show button that opens the map there
local function feeder_row(list, icon, caption, entity)
  local row = list.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  if entity and entity.valid then
    local p = entity.position
    row.add{type = "button", caption = {"line-loss-grid.show"}, style = "mini_button_aligned_to_text_vertically",
      tags = {line_loss_goto = true, x = p.x, y = p.y, surface = entity.surface.name, ends = {{p.x, p.y}}}}
  end
  row.add{type = "label", caption = {"", "[img=entity/" .. icon .. "] ", caption}}
end

-- The list: the tracked transformer, then what feeds it
local function feeders_list(player, tracked, feeders)
  local frame = player.gui.screen[FEEDERS_PANEL]
  if not (frame and frame.list) then return end
  local list = frame.list
  list.clear()
  if not (tracked and tracked.valid) then
    if (storage.feeders_on or {})[player.index] then list.add{type = "label", caption = {"line-loss-feeders.pick"}} end
    return
  end
  feeder_row(list, tracked.name, tracked.localised_name, tracked)
  list.add{type = "label", caption = {"line-loss-feeders.fed-by"}, style = "caption_label"}
  for _, f in ipairs(feeders) do
    if f.entity then
      feeder_row(list, f.entity.name, {"line-loss-feeders.transformer", f.entity.localised_name,
        string.format("%.0f", 100 * f.share)}, f.entity)
    else
      feeder_row(list, f.name, {"line-loss-feeders.generators", prototypes.entity[f.name] and
        prototypes.entity[f.name].localised_name or f.name, f.count}, f.at)
    end
  end
end

-- Generator poles on a network, found once per network data rebuild
local function generator_poles(st, net, topo)
  st.gen_cache = st.gen_cache or {}
  local cached = st.gen_cache[net]
  if cached and cached.topo == topo then return cached.poles end
  local poles = {}
  for pole, g in pairs(topo and topo.gen_at or {}) do
    local e = entity_of(pole)
    if e and e.valid and e.electric_network_id == net then poles[#poles + 1] = {e = e, g = g} end
  end
  st.gen_cache[net] = {topo = topo, poles = poles}
  return poles
end

-- Feeders: with the panel's box ticked, the transformer hovered or opened
-- (kept when nothing is) gets an arrow above it, and each of its sources an
-- icon: feeding transformers, and the poles picking up the generators on its
-- upstream network (the game spreads production over all of them)
local function update_highlight(st, player, tick)
  local index = player.index
  local on = false
  for _, shortcut in pairs(MODES) do
    if player.is_shortcut_toggled(shortcut) then on = true end
  end
  if not on then
    clear_highlight(st, index)
    local frame = player.gui.screen[FEEDERS_PANEL]
    if frame then frame.destroy() end
    return
  end
  local panel = feeders_panel(player)
  local types_box = panel["line-loss-network-types"]
  if not types_box then
    -- a panel left open by an older version
    panel.destroy()
    panel = feeders_panel(player)
    types_box = panel["line-loss-network-types"]
  end
  local networks_on = player.is_shortcut_toggled(MODES.networks)
  if types_box and types_box.visible ~= networks_on then types_box.visible = networks_on end
  local shown = st.highlight[index]
  if not (storage.feeders_on or {})[index] then
    clear_highlight(st, index)
    feeders_list(player, nil)
    return
  end
  local transformer = hovered_transformer(player)
  if not transformer then
    local opened = player.opened
    if opened and player.opened_gui_type == defines.gui_type.entity and opened.valid
        and TRANSFORMER_NAMES[opened.name] then
      transformer = opened
    end
  end
  local unit = transformer and transformer.unit_number
  if not unit and shown and storage.transformers[shown.unit] then unit = shown.unit end
  local parts = unit and storage.transformers[unit]
  if not parts then
    clear_highlight(st, index)
    feeders_list(player, nil)
    return
  end
  if shown and shown.unit == unit and tick - shown.tick < FEEDER_REFRESH then return end
  clear_highlight(st, index)
  local objs, feeders = {}, {}
  -- the arrow turned upside down; top-aligned so that, turned, it sits above
  marker(objs, player, parts.transformer, "[img=utility/indication_arrow]", "top", 0.5)
  local pin = parts.pole_in
  local net = pin and pin.valid and pin.electric_network_id
  -- by default feeders sending a negligible share are left out; unticked, every
  -- transformer feeding the input's network is listed, 0% ones included
  local setting = player.mod_settings["line-loss-feeders-neglect-low"]
  local neglect = not setting or setting.value ~= false
  local listed = {}
  for source, share in pairs(parts.kirch_shares or {}) do
    local feeder = source ~= "gen" and storage.transformers[source]
    local e = feeder and feeder.transformer
    if e and e.valid and (share > 0.001 or not neglect) then
      marker(objs, player, e, "[img=entity/" .. e.name .. "]")
      feeders[#feeders + 1] = {entity = e, share = share}
      listed[source] = true
    end
  end
  if not neglect and net then
    for source, other in pairs(storage.transformers) do
      local pout, e = other.pole_out, other.transformer
      if source ~= unit and not listed[source] and pout and pout.valid and pout.electric_network_id == net
          and e and e.valid then
        marker(objs, player, e, "[img=entity/" .. e.name .. "]")
        feeders[#feeders + 1] = {entity = e, share = 0}
      end
    end
  end
  table.sort(feeders, function(a, b) return a.share > b.share end)
  local topo = (storage.kirchhoff or {}).topo
  if net and topo and next(parts.kirch_gen_src or {}) then
    local by_name, n = {}, 0
    for _, gp in ipairs(generator_poles(st, net, topo)) do
      local g = gp.g
      local name = g.name or (g.w == 0 and g.s > 0 and "solar-panel" or "steam-engine")
      if not prototypes.entity[name] then name = "steam-engine" end
      if n < MAX_GEN_MARKERS then
        marker(objs, player, gp.e, "[img=entity/" .. name .. "]")
        n = n + 1
      end
      for gname, c in pairs(g.count or {[name] = 1}) do
        local entry = by_name[gname]
        if not entry then entry = {name = gname, count = 0, best = 0}; by_name[gname] = entry end
        entry.count = entry.count + c
        if c > entry.best then entry.best, entry.at = c, gp.e end
      end
    end
    local gens = {}
    for _, entry in pairs(by_name) do gens[#gens + 1] = entry end
    table.sort(gens, function(a, b) return a.count > b.count end)
    for _, entry in ipairs(gens) do feeders[#feeders + 1] = entry end
  end
  st.highlight[index] = {unit = unit, tick = tick, objs = objs}
  feeders_list(player, parts.transformer, feeders)
end

-- The panel's box
---@param event EventData.on_gui_checked_state_changed
function feeders_on_checked(event)
  local element = event.element
  if not (element and element.valid) then return end
  if element.name == "line-loss-network-types" then
    storage.network_types_on = storage.network_types_on or {}
    storage.network_types_on[event.player_index] = element.state or nil
    local st = state()
    redraw(game.tick)
    for m, view in pairs(st.modes) do
      if view.queue then draw_queued(m, view, DRAWS_PER_TICK) end
    end
    return
  end
  if element.name ~= "line-loss-feeders-toggle" then return end
  storage.feeders_on = storage.feeders_on or {}
  storage.feeders_on[event.player_index] = element.state or nil
  local player = game.get_player(event.player_index)
  local st = state()
  clear_highlight(st, event.player_index)
  if player then update_highlight(st, player, game.tick) end
end

---@param player LuaPlayer
---@param mode "power"|"rated"|"losses"
local function toggle(player, mode)
  local on = not player.is_shortcut_toggled(MODES[mode])
  player.set_shortcut_toggled(MODES[mode], on)
  if on then
    -- one view at a time
    for other, shortcut in pairs(MODES) do
      if other ~= mode and player.is_shortcut_toggled(shortcut) then player.set_shortcut_toggled(shortcut, false) end
    end
  end
  local st = state()
  redraw(game.tick)
  for m, view in pairs(st.modes) do
    if view.queue then draw_queued(m, view, DRAWS_PER_TICK) end
  end
  update_hover(st)
  update_highlight(st, player, game.tick)
  apply_po_overlay()
  if mode == "losses" then update_grid_diagram(game.tick, true) end
end

function toggle_line_loading(player) toggle(player, "power") end
function toggle_line_loading_rated(player) toggle(player, "rated") end
function toggle_line_losses(player) toggle(player, "losses") end
function toggle_line_networks(player) toggle(player, "networks") end

---@param tick GameTick
function update_line_loading(tick)
  if not storage.settings.enabled then return end
  local active = local_overload()
  local st = state()
  if tick % REFRESH_INTERVAL == 37 then redraw(tick) end
  for mode, view in pairs(st.modes) do
    if view.queue then draw_queued(mode, view, DRAWS_PER_TICK) end
  end
  -- Power Overload redraws its pole text when the hovered pole changes, in its
  -- own on_tick, which runs before ours: hidden in the same tick, no flash
  if active then
    local sel = st.po_selected or {}
    st.po_selected = sel
    local changed = false
    for _, player in pairs(game.connected_players) do
      local e = player.selected
      local unit = e and e.valid and e.type == "electric-pole" and e.unit_number or nil
      if sel[player.index] ~= unit then
        sel[player.index] = unit
        if unit then changed = true end
      end
    end
    if changed then hide_po_hover(st) end
  end
  if tick % HOVER_INTERVAL == 0 then
    update_hover(st)
    for _, player in pairs(game.connected_players) do update_highlight(st, player, tick) end
    for index in pairs(st.highlight) do
      local player = game.get_player(index)
      if not (player and player.connected) then clear_highlight(st, index) end
    end
  end
  -- new Power Overload drawings (after a network change) hidden within 1 s
  if tick % 60 == 0 and (#any_viewers() > 0 or next((storage.po_overlay or {}).hidden or {})) then
    apply_po_overlay()
  end
  if active then
    -- Power Overload's hover: hidden when a pole is hovered, and once more a
    -- little later in case it was drawn after
    if st.hover_changed then
      st.hover_changed, st.rescan = nil, tick + 30
      hide_po_hover(st)
    elseif st.rescan and tick >= st.rescan then
      st.rescan = nil
      hide_po_hover(st)
    end
    local delay = DELAY[storage.settings.pole_overload] or 300
    check_overload(st, "pole", delay)
    check_overload(st, "fuse", delay)
    st.warned = nil
  elseif not st.warned then
    -- once per save, again after the setting was changed back
    st.warned = true
    game.print({"line-loss-loading.po-setting"})
  end
end

function line_loading_clear_all()
  if not storage.line_loading then
    apply_po_overlay()  -- (gives back what an older view hid)
    return
  end
  local st = state()
  for _, view in pairs(st.modes) do clear_mode(view) end
  for index, shown in pairs(st.hover) do
    if shown.obj and shown.obj.valid then shown.obj.destroy() end
    st.hover[index] = nil
  end
  for index in pairs(st.highlight) do clear_highlight(st, index) end
  for _, player in pairs(game.players) do
    for _, shortcut in pairs(MODES) do
      if player.is_shortcut_toggled(shortcut) then player.set_shortcut_toggled(shortcut, false) end
    end
  end
  apply_po_overlay()
end
