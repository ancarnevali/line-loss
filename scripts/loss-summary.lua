-- Surface summary panel, shown with the losses view: everything generated on
-- the player's surface, what reaches machines, and every loss, over the last
-- 5 s of the game's own electric statistics. Each hidden consumer sits on the
-- network whose loss it stands for, so summing the networks counts every loss
-- once:
--   "Line loss" on a network: that network's wires (charged at the output of
--     the transformer feeding it, or at the input of a generator-fed one);
--   "Transformer losses" on a network: the transformers feeding it.
-- Split: line loss by network type (generator-fed inputs apart), transformer
-- losses into inefficiency and core loss in the ratio of the values set.

local PANEL = "line-loss-summary"

---@param surface LuaSurface
---@param tick GameTick
local function summarise(surface, tick)
  local poles = {}      -- network id -> a pole of it
  local gen_line = {}   -- network id -> generator line loss set on it
  local ineff_set, core_set, transformers = 0, 0, 0
  local function add(pole)
    if pole and pole.valid and pole.surface == surface then
      local net = pole.electric_network_id
      if net and not poles[net] then poles[net] = pole end
    end
  end
  for _, parts in pairs(storage.transformers or {}) do
    local e = parts.transformer
    if e and e.valid and e.surface == surface then
      transformers = transformers + 1
      add(parts.pole_in)
      add(parts.pole_out)
      ineff_set = ineff_set + (parts.ineff_burn or 0)
      core_set = core_set + (parts.no_load_burn or 0)
      local pin = parts.pole_in
      if (parts.gen_burn or 0) > 0 and pin and pin.valid then
        local net = pin.electric_network_id
        if net then gen_line[net] = (gen_line[net] or 0) + parts.gen_burn end
      end
    end
  end
  -- networks with generators and no transformer
  local topo = storage.kirchhoff and storage.kirchhoff.topo
  local graph = storage.wire_graph or {}
  for unit in pairs(topo and topo.gen_at or {}) do
    local node = graph[unit]
    add(node and node.e)
  end

  local s = {generated = 0, delivered = 0, line = {transmission = 0, distribution = 0, generators = 0},
    transformer_losses = 0, networks = {transmission = 0, distribution = 0}, transformers = transformers}
  for net, pole in pairs(poles) do
    local loads = get_network_loads(pole, tick)
    s.generated = s.generated + (loads.generated or 0)
    s.delivered = s.delivered + loads.machines
    local kind = kirchhoff_network_kind(pole.unit_number) or "distribution"
    s.networks[kind] = s.networks[kind] + 1
    local from_gens = math.min(gen_line[net] or 0, loads.line)
    s.line.generators = s.line.generators + from_gens
    s.line[kind] = s.line[kind] + loads.line - from_gens
    s.transformer_losses = s.transformer_losses + loads.ineff
  end
  local split = ineff_set + core_set > 0 and ineff_set / (ineff_set + core_set) or 1
  s.ineff = s.transformer_losses * split
  s.core = s.transformer_losses - s.ineff
  s.lost = s.line.transmission + s.line.distribution + s.line.generators + s.transformer_losses
  return s
end

local function power(w) return ratings.format_power(w) end
local function share(w, generated)
  if generated <= 0 then return {"line-loss-summary.power", power(w)} end
  return {"line-loss-summary.power-share", power(w), string.format("%.1f", w / generated * 100)}
end

---@param player LuaPlayer
function destroy_loss_summary(player)
  local frame = player.gui.screen[PANEL]
  if frame then frame.destroy() end
end

---@param player LuaPlayer
local function panel(player)
  local frame = player.gui.screen[PANEL]
  if frame then return frame end
  frame = player.gui.screen.add{type = "frame", name = PANEL, direction = "vertical"}
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", name = "title", caption = "", style = "frame_title", ignored_by_interaction = true}
  local handle = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  handle.style.horizontally_stretchable = true
  handle.style.height = 24
  handle.style.minimal_width = 24
  frame.add{type = "flow", name = "content", direction = "vertical"}
  local saved = storage.summary_location and storage.summary_location[player.index]
  frame.location = saved or {x = 0, y = math.floor(player.display_resolution.height * 0.15)}
  return frame
end

---@param element LuaGuiElement
---@param player_index uint
function loss_summary_on_moved(element, player_index)
  if element.name == PANEL then
    storage.summary_location = storage.summary_location or {}
    storage.summary_location[player_index] = element.location
  end
end

---@param player LuaPlayer
---@param s table
local function fill(player, s)
  local frame = panel(player)
  local surface = player.surface
  local planet = surface.planet
  local name = surface.localised_name or (planet and planet.prototype.localised_name) or surface.name
  frame.children[1].title.caption = {"line-loss-summary.title", name}
  local content = frame.content
  content.clear()
  local function label(caption, tooltip, style)
    local l = content.add{type = "label", caption = caption, tooltip = tooltip}
    if style then l.style.font = style end
    return l
  end
  if s.generated <= 0 and s.lost <= 0 then
    label({"line-loss-summary.nothing"})
    return
  end
  local g = s.generated
  label({"line-loss-summary.generated", power(g)}, {"line-loss-summary.generated-tooltip"})
  label({"line-loss-summary.delivered", share(s.delivered, g)}, {"line-loss-summary.share-tooltip"})
  label({"line-loss-summary.lost", share(s.lost, g)}, {"line-loss-summary.share-tooltip"}, "default-bold")
  label({"line-loss-summary.line-transmission", share(s.line.transmission, g)})
  label({"line-loss-summary.line-distribution", share(s.line.distribution, g)})
  label({"line-loss-summary.line-generators", share(s.line.generators, g)}, {"line-loss-summary.line-generators-tooltip"})
  label({"line-loss-summary.ineff", share(s.ineff, g)})
  label({"line-loss-summary.core", share(s.core, g)})
  label({"line-loss-summary.counts", s.networks.transmission, s.networks.distribution, s.transformers})
end

-- Called by the grid diagram's update (every 60 ticks, viewers only)
---@param player_indices uint[]
---@param tick GameTick
function update_loss_summary(player_indices, tick)
  local by_surface = {}
  for _, index in pairs(player_indices) do
    local player = game.get_player(index)
    if player and player.connected then
      local surface = player.surface
      local s = by_surface[surface.index]
      if not s then
        s = summarise(surface, tick)
        by_surface[surface.index] = s
      end
      fill(player, s)
    end
  end
end
