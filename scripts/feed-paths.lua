-- Feed paths: for the transformer a player last hovered or opened, the
-- shortest resistance-weighted wire paths to the sources assigned to it (the
-- transformers whose share reaches it, or, on a generator network, the poles
-- with the most generator output nearby). Each path is coloured by the line
-- loss accumulated from its source, so it turns from green to red as the
-- power travels; width shows the source's share. A label at each source gives
-- its share and its route's line loss.
--
-- Map view and world, per player, toggled with the "Toggle feed paths"
-- shortcut. While it is on, Power Overload's network colouring (its map
-- lines and dots) is hidden for that player, so the paths stand out, and
-- restored when it is turned off.
--
-- The paths come from one extra search from the transformer's input pole
-- across its upstream network (wires work both ways, so the shortest path
-- from a source to it is the shortest path from it to the source), run over
-- a few ticks and repeated every REFRESH_INTERVAL ticks while shown.

local SHORTCUT = "line-loss-toggle-feed-paths"
local POLES_PER_TICK = 300
local REFRESH_INTERVAL = 300
local PO_OVERLAY_INTERVAL = 60
local MAX_GENERATOR_TARGETS = 8

-- Colour by route loss, as the line-loss map
local STEPS = {0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, math.huge}
local COLOURS = {
  {r = 0.20, g = 0.90, b = 0.20},
  {r = 0.45, g = 0.90, b = 0.15},
  {r = 0.70, g = 0.90, b = 0.10},
  {r = 1.00, g = 0.85, b = 0.10},
  {r = 1.00, g = 0.60, b = 0.10},
  {r = 1.00, g = 0.40, b = 0.15},
  {r = 1.00, g = 0.20, b = 0.20},
  {r = 0.70, g = 0.00, b = 0.20},
}
local function colour_for(loss)
  for i, bound in ipairs(STEPS) do
    if loss < bound then return COLOURS[i] end
  end
  return COLOURS[#COLOURS]
end

local function state()
  storage.feed_paths = storage.feed_paths or {targets = {}, shown = {}, jobs = {}, po_hidden = {}}
  return storage.feed_paths
end

local function destroy(id)
  if not id then return end
  local object = rendering.get_object_by_id(id)
  if object and object.valid then object.destroy() end
end

local function clear_drawing(st, player_index)
  local shown = st.shown[player_index]
  if shown then
    for _, id in pairs(shown.ids) do destroy(id) end
    st.shown[player_index] = nil
  end
end

-- Power Overload's network colouring ---------------------------------------------

-- Its map lines and dots (chart-mode lines and circles it draws). Hidden for
-- the players with feed paths on by narrowing the objects' player list, and
-- given back to everyone when nobody has them on. Its texts (network names,
-- pole readouts) are left alone.
local function apply_po_overlay(st)
  local hiders, viewers = {}, {}
  for _, player in pairs(game.connected_players) do
    if player.is_shortcut_toggled(SHORTCUT) then
      hiders[#hiders + 1] = player.index
    else
      viewers[#viewers + 1] = player.index
    end
  end
  local ok, objects = pcall(rendering.get_all_objects, "PowerOverload")
  if not ok or not objects then return end
  for _, object in pairs(objects) do
    if object.valid and object.render_mode == "chart" and (object.type == "line" or object.type == "circle") then
      local id = object.id
      if #hiders == 0 then
        if st.po_hidden[id] then
          pcall(function()
            object.visible = true
            object.players = {}
          end)
        end
      else
        pcall(function()
          if #viewers == 0 then
            object.visible = false
          else
            object.visible = true
            object.players = viewers
          end
        end)
        st.po_hidden[id] = true
      end
    end
  end
  if #hiders == 0 then st.po_hidden = {} end
end

-- Search ---------------------------------------------------------------------------

local function new_job(player_index, unit)
  local parts = storage.transformers[unit]
  local start = parts and parts.pole_in
  if not (start and start.valid) then return nil end
  local job = {
    player = player_index, unit = unit, start = start.unit_number,
    heap = {}, dist = {[start.unit_number] = 0}, prev = {}, done = {}, poles = {},
    targets = {}, remaining = 0, generators = nil,
  }
  local feeders = get_assigned_feeders(unit)
  if feeders then
    for _, f in ipairs(feeders) do
      local source = storage.transformers[f.source]
      local pole = source and source.pole_out
      if pole and pole.valid then
        job.targets[pole.unit_number] = {share = f.share, source = f.source}
        job.remaining = job.remaining + 1
      end
    end
    if job.remaining == 0 then return nil end
  elseif parts.gen_loss_all then
    job.generators = {seen = {}, poles = {}}
  else
    return nil
  end
  line_loss_search.heap_push(job.heap, {0, start.unit_number, start})
  return job
end

-- Rated generator output in a pole's supply area, each generator counted once
local function generator_output(job, pole, name)
  local r = line_loss_search.supply_distance(pole, name)
  if r <= 0 then return 0 end
  local p = pole.position
  local found = pole.surface.find_entities_filtered{
    area = {{p.x - r, p.y - r}, {p.x + r, p.y + r}},
    type = line_loss_search.generator_types(pole.surface),
  }
  local w, seen = 0, job.generators.seen
  for _, generator in pairs(found) do
    local id = generator.unit_number
    if id and not seen[id] then
      seen[id] = true
      w = w + line_loss_search.rated_output(generator)
    end
  end
  return w
end

---@return boolean finished
local function step(job, budget)
  local info_of = line_loss_search.info_of
  local heap, dist, done = job.heap, job.dist, job.done
  while budget > 0 and #heap > 0 do
    local item = line_loss_search.heap_pop(heap)
    local d, unit_number, pole = item[1], item[2], item[3]
    if not done[unit_number] and pole.valid then
      done[unit_number] = true
      job.poles[unit_number] = pole
      budget = budget - 1
      local name = pole.name
      local info = info_of(name)
      if job.targets[unit_number] then
        job.remaining = job.remaining - 1
        if job.remaining <= 0 then return true end
      end
      if job.generators and not info.hidden then
        local w = generator_output(job, pole, name)
        if w > 0 then job.generators.poles[#job.generators.poles + 1] = {unit = unit_number, w = w} end
      end
      if unit_number == job.start or not info.hidden then
        local connector = pole.get_wire_connector(defines.wire_connector_id.pole_copper, false)
        if connector then
          local p1 = pole.position
          for _, connection in pairs(connector.connections) do
            local other = connection.target.owner
            local other_info = info_of(other.name)
            if other_info.pole then
              local other_unit = other.unit_number
              if not done[other_unit] then
                local p2 = other.position
                local dx, dy = p2.x - p1.x, p2.y - p1.y
                local new_d = d + math.sqrt(dx * dx + dy * dy) * 0.5 * (info.r + other_info.r)
                local best = dist[other_unit]
                if not best or new_d < best then
                  dist[other_unit] = new_d
                  job.prev[other_unit] = unit_number
                  line_loss_search.heap_push(heap, {new_d, other_unit, other})
                end
              end
            end
          end
        end
      end
    end
  end
  return #heap == 0
end

-- Drawing --------------------------------------------------------------------------

local function draw(job, player)
  local st = state()
  clear_drawing(st, player.index)
  -- Generator networks: the poles with the most generator output nearby
  if job.generators then
    local list = job.generators.poles
    table.sort(list, function(a, b) return a.w > b.w end)
    local total = 0
    for i = 1, math.min(#list, MAX_GENERATOR_TARGETS) do total = total + list[i].w end
    for i = 1, math.min(#list, MAX_GENERATOR_TARGETS) do
      job.targets[list[i].unit] = {share = total > 0 and list[i].w / total or 0}
    end
  end
  local ids = {}
  for target_unit, target in pairs(job.targets) do
    local total_d = job.dist[target_unit]
    if total_d and job.done[target_unit] then
      local width = 3 + 7 * (target.share or 0)
      local unit = target_unit
      while job.prev[unit] do
        local a, b = job.poles[unit], job.poles[job.prev[unit]]
        if not (a and b and a.valid and b.valid) then break end
        -- loss accumulated from the source up to the middle of this wire
        local from_source = total_d - 0.5 * (job.dist[unit] + job.dist[job.prev[unit]])
        local colour = colour_for(get_route_line_loss(math.max(from_source, 0)))
        for _, mode in pairs({"chart", "game"}) do
          ids[#ids + 1] = rendering.draw_line{
            color = colour, width = mode == "chart" and width or width * 0.6,
            from = a, to = b, surface = a.surface, players = {player}, render_mode = mode,
          }.id
        end
        unit = job.prev[unit]
      end
      local source_pole = job.poles[target_unit]
      if source_pole and source_pole.valid then
        local text = {"line-loss-feed.label", string.format("%.0f", (target.share or 0) * 100),
          string.format("%.1f", get_route_line_loss(total_d) * 100)}
        for _, mode in pairs({"chart", "game"}) do
          ids[#ids + 1] = rendering.draw_text{
            text = text, surface = source_pole.surface, target = {entity = source_pole, offset = {0, -2}},
            color = colour_for(get_route_line_loss(total_d)), scale = mode == "chart" and 3 or 1.5,
            alignment = "center", players = {player}, render_mode = mode,
          }.id
        end
      end
    end
  end
  st.shown[player.index] = {unit = job.unit, ids = ids, tick = game.tick}
end

-- Public -----------------------------------------------------------------------------

---@param player_index uint
---@param unit UnitNumber
function feed_paths_set_target(player_index, unit)
  local st = state()
  if st.targets[player_index] == unit then return end
  st.targets[player_index] = unit
  local player = game.get_player(player_index)
  if player and player.is_shortcut_toggled(SHORTCUT) then
    st.jobs[player_index] = new_job(player_index, unit)
  end
end

---@param player LuaPlayer
function toggle_feed_paths(player)
  local st = state()
  local on = not player.is_shortcut_toggled(SHORTCUT)
  player.set_shortcut_toggled(SHORTCUT, on)
  if on then
    local unit = st.targets[player.index]
    st.jobs[player.index] = unit and new_job(player.index, unit) or nil
    if not st.jobs[player.index] then
      player.create_local_flying_text{text = {"line-loss-feed.pick"}, create_at_cursor = true}
    end
  else
    st.jobs[player.index] = nil
    clear_drawing(st, player.index)
  end
  apply_po_overlay(st)
end

---@param tick GameTick
function update_feed_paths(tick)
  local st = storage.feed_paths
  if not st then return end
  for player_index, job in pairs(st.jobs) do
    local player = game.get_player(player_index)
    if not (player and player.connected and player.is_shortcut_toggled(SHORTCUT)) then
      st.jobs[player_index] = nil
    elseif step(job, POLES_PER_TICK) then
      st.jobs[player_index] = nil
      draw(job, player)
    end
  end
  for player_index, shown in pairs(st.shown) do
    local player = game.get_player(player_index)
    if not (player and player.connected and player.is_shortcut_toggled(SHORTCUT)) then
      clear_drawing(st, player_index)
    elseif tick - shown.tick >= REFRESH_INTERVAL and not st.jobs[player_index] then
      st.jobs[player_index] = new_job(player_index, st.targets[player_index] or shown.unit)
      shown.tick = tick
    end
  end
  if tick % PO_OVERLAY_INTERVAL == 0 and (next(st.shown) or next(st.jobs) or next(st.po_hidden)) then
    apply_po_overlay(st)
  end
end

-- Everything off (setup, line losses switched off)
function feed_paths_clear_all()
  local st = storage.feed_paths
  if not st then return end
  for player_index in pairs(st.shown) do clear_drawing(st, player_index) end
  st.jobs = {}
  for _, player in pairs(game.players) do
    if player.is_shortcut_toggled(SHORTCUT) then player.set_shortcut_toggled(SHORTCUT, false) end
  end
  apply_po_overlay(st)
end
