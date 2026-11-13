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
-- In any view, hovering a transformer highlights the wires carrying its power
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
-- Networks view: transmission networks blue; on distribution networks, each
-- wire in the colour of the transformer feeding its poles (one colour per
-- transformer), grey where poles fed by different sources meet
local TRANSMISSION = {r = 0.25, g = 0.55, b = 1, a = 0.9}
local BOUNDARY = {r = 0.5, g = 0.5, b = 0.5, a = 0.8}
local SOURCE_PALETTE = {
  {r = 0.9, g = 0.3, b = 0.2}, {r = 0.2, g = 0.75, b = 0.45}, {r = 0.75, g = 0.35, b = 0.85},
  {r = 1, g = 0.55, b = 0.1}, {r = 0.1, g = 0.75, b = 0.8}, {r = 0.9, g = 0.4, b = 0.6},
  {r = 0.55, g = 0.8, b = 0.2}, {r = 0.6, g = 0.45, b = 0.3},
}
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
local function look(mode, step)
  if mode == "networks" then
    if step == 1 then return TRANSMISSION, 9 end
    if step == 2 then return BOUNDARY, 4.5 end
    if step >= 10 then return SOURCE_PALETTE[(step - 10) % #SOURCE_PALETTE + 1], 9 end
    return IDLE, 2
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
  for mode in pairs(MODES) do st.modes[mode] = st.modes[mode] or {wires = {}} end
  st.highlight = st.highlight or {}
  return st
end

local function viewers(mode)
  local list = {}
  for _, player in pairs(game.connected_players) do
    if player.is_shortcut_toggled(MODES[mode]) then list[#list + 1] = player.index end
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
  for _, wire in pairs(view.wires) do
    if wire.obj and wire.obj.valid then wire.obj.destroy() end
  end
  view.wires, view.queue, view.queue_pos = {}, nil, nil
end

local function draw_mode(mode, view, players, loads, wanted, vmax)
  local players_key = table.concat(players, ",")
  local seen, queue = {}, {}
  for key, wire in pairs(wanted) do
    local entry = loads[key]
    local w = entry and entry.w or 0
    local step = 0
    if mode == "networks" then
      local kind = kirchhoff_network_kind(wire.a) or kirchhoff_network_kind(wire.b)
      if kind == "transmission" then
        step = 1
      elseif kind == "distribution" then
        local sa, sb = kirchhoff_pole_source(wire.a), kirchhoff_pole_source(wire.b)
        local src = (sa == nil and sb) or (sb == nil and sa) or (sa == sb and sa) or nil
        if sa ~= nil and sb ~= nil and sa ~= sb then step = 2
        elseif type(src) == "number" then step = 10 + src % #SOURCE_PALETTE end
      end
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
  view.queue, view.queue_pos, view.players_key = queue, 1, players_key
end

local function draw_queued(mode, view, budget)
  local queue, pos = view.queue, view.queue_pos or 1
  if not queue then return end
  local players
  while budget > 0 and pos <= #queue do
    local item = queue[pos]
    pos = pos + 1
    if not view.wires[item.key] then
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
  for mode in pairs(MODES) do
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
  for mode in pairs(MODES) do
    if #players[mode] > 0 then draw_mode(mode, st.modes[mode], players[mode], loads, wanted, vmax) end
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

-- Hovered transformer: the routes from what feeds it, white, wider for a
-- bigger share, labelled at each source with its share and line loss. From
-- feeding transformers along their search trees; for a transformer fed by
-- generators, from the 8 poles with the most generator output nearby.
local HIGHLIGHT_REFRESH = 300
local WHITE = {r = 1, g = 1, b = 1, a = 0.9}

local function clear_highlight(st, index)
  local shown = st.highlight[index]
  if not shown then return end
  for _, obj in pairs(shown.objs) do
    if obj.valid then obj.destroy() end
  end
  st.highlight[index] = nil
end

-- One wire of a feed: width by the share of the transformer's power it carries
local function draw_wire(objs, player, a, b, share)
  if a and b and a.valid and b.valid and a.surface == b.surface then
    objs[#objs + 1] = rendering.draw_line{
      color = WHITE, width = 3 + 9 * share, from = a, to = b, surface = a.surface,
      players = {player}, render_mode = "chart",
    }
  end
end

local function draw_label(objs, player, entity, share, loss)
  if not entity then return end
  objs[#objs + 1] = rendering.draw_text{
    text = {"line-loss-feed.label", string.format("%.0f", 100 * share), string.format("%.1f", 100 * loss)},
    surface = entity.surface, target = entity, color = WHITE, scale = 4,
    alignment = "center", vertical_alignment = "bottom", players = {player}, render_mode = "chart",
  }
end

local function update_highlight(st, player, tick)
  local index = player.index
  local on = false
  for _, shortcut in pairs(MODES) do
    if player.is_shortcut_toggled(shortcut) then on = true end
  end
  local transformer = on and hovered_transformer(player)
  local unit = transformer and transformer.unit_number
  local shown = st.highlight[index]
  if not unit then
    clear_highlight(st, index)
    return
  end
  if shown and shown.unit == unit and tick - shown.tick < HIGHLIGHT_REFRESH then return end
  clear_highlight(st, index)
  local parts = storage.transformers[unit]
  local pin = parts and parts.pole_in
  if not (pin and pin.valid) then return end
  -- the wires carrying its power, as the last refresh assigned them (Kirchhoff
  -- flows on transmission, nearest sources on distribution), labelled at each
  -- source with its share and the upstream line loss
  local objs = {}
  local merged = {}
  for _, w in ipairs(parts.kirch_feed or {}) do
    local k = w[1] < w[2] and (w[1] .. ":" .. w[2]) or (w[2] .. ":" .. w[1])
    merged[k] = merged[k] or {w[1], w[2], 0}
    merged[k][3] = merged[k][3] + w[3]
  end
  for _, w in pairs(merged) do draw_wire(objs, player, entity_of(w[1]), entity_of(w[2]), math.min(w[3], 1)) end
  local up = get_upstream_line_loss(unit) or 0
  for source, share in pairs(parts.kirch_shares or {}) do
    local feeder = source ~= "gen" and storage.transformers[source]
    if feeder and share > 0.001 then draw_label(objs, player, feeder.transformer, share, up) end
  end
  for pole, share in pairs(parts.kirch_gen_src or {}) do
    if share > 0.001 then draw_label(objs, player, entity_of(pole), share, up) end
  end
  st.highlight[index] = {unit = unit, tick = tick, objs = objs}
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
