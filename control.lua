util = require("util")  -- Power Overload's shared.lua uses the global util
shared = require("__PowerOverload__/shared")
ratings = require("__line-loss__/scripts/ratings")
require("__line-loss__/scripts/transformers")
require("__line-loss__/scripts/line-losses")
require("__line-loss__/scripts/grid-diagram")
require("__line-loss__/scripts/hover")
require("__line-loss__/scripts/heatmap")
require("__line-loss__/scripts/feed-paths")
require("__line-loss__/scripts/transformer-panel")

-- Settings -----------------------------------------------------------------------

local function read_settings()
  local global = settings.global
  local po_efficiency = global["power-overload-transformer-efficiency"]
  storage.settings = {
    enabled = global["line-loss-enabled"].value,
    per_tile = global["line-loss-per-tile"].value,
    closeness = global["line-loss-closeness"].value,
    efficiency = global["line-loss-transformer-efficiency"].value,
    no_load = global["line-loss-no-load"].value / 100,
    machine_weighting = global["line-loss-machine-weighting"].value,
    po_efficiency = po_efficiency and po_efficiency.value or 1,
  }
end

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  local name = event.setting
  if name == "line-loss-show-idle-routes" then
    update_grid_diagram(event.tick, true)
    return
  end
  if string.sub(name, 1, 10) == "line-loss-" or name == "power-overload-transformer-efficiency" then
    local old = storage.settings or {}
    read_settings()
    local new = storage.settings
    if not new.enabled then
      reset_hover()
      grid_diagram_clear()
      heatmap_clear()
      feed_paths_clear_all()
    elseif not old.enabled or new.per_tile ~= old.per_tile or new.closeness ~= old.closeness
        or new.machine_weighting ~= old.machine_weighting then
      -- Searched again: switched back on (nothing was kept up to date while
      -- off), per-pole losses, sharing, machine counts
      mark_all_line_loss_dirty()
    end
  end
end)

-- Setup ----------------------------------------------------------------------------

local function setup()
  storage.transformers = storage.transformers or {}
  read_settings()
  reset_hover()
  grid_diagram_clear()
  heatmap_clear()  -- also clears the dots of the old "power lost per pole" view
  feed_paths_clear_all()
  -- Legend window from 0.1.2 (removed)
  for _, player in pairs(game.players) do
    local legend = player.gui.screen["line-loss-map-legend"]
    if legend then legend.destroy() end
  end
  storage.legend_location = nil
  -- High- and low-priority transformers are hidden (data-final-fixes): lock
  -- their recipes in saves that had unlocked them
  for _, force in pairs(game.forces) do
    for _, name in pairs({"po-transformer-high", "po-transformer-low"}) do
      local recipe = force.recipes[name]
      if recipe then recipe.enabled = false end
    end
  end
  scan_transformers()
  init_line_losses()  -- after the scan, so every transformer is queued
end

script.on_init(setup)
script.on_configuration_changed(setup)

-- Transformers ---------------------------------------------------------------------

-- Built and removed entities:
--   * transformers are registered when built (removal: on_object_destroyed);
--   * a pole built or removed re-runs the searches of the transformers on its
--     network (removed poles are seen just before removal, while they still
--     know their network);
--   * with machine weighting on, any other electric entity built or removed
--     does the same, so the per-pole machine counts stay current.
-- Not filtered, because machines can be of any type; non-matching entities
-- return straight away.

---@param entity LuaEntity
---@return uint?
local function network_of(entity)
  local ok, id = pcall(function() return entity.electric_network_id end)
  if ok and id then return id end
  -- Fall back to a pole whose supply area it may sit in
  local pole = entity.surface.find_entities_filtered{type = "electric-pole", position = entity.position, radius = 8, limit = 1}[1]
  return pole and pole.electric_network_id or nil
end

local function on_entity_changed(event, removed)
  local entity = event.entity or event.destination
  if not (entity and entity.valid) then return end
  if TRANSFORMER_NAMES[entity.name] then
    if not removed then register_transformer(entity) end
  elseif entity.type == "electric-pole" then
    wire_graph_pole_changed(entity)
    mark_line_loss_network(entity.electric_network_id)
  elseif entity.type ~= "entity-ghost" and ((storage.settings and storage.settings.machine_weighting)
      or line_loss_search.is_generator(entity)) then
    -- Generators weight their network's generator search; machines, with
    -- machine weighting on, the poles powering them
    mark_line_loss_network(network_of(entity))
  end
end
for _, event_id in pairs({
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.on_space_platform_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
  defines.events.on_entity_cloned,
}) do
  script.on_event(event_id, function(event) on_entity_changed(event, false) end)
end
for _, event_id in pairs({
  defines.events.on_pre_player_mined_item,
  defines.events.on_robot_pre_mined,
  defines.events.on_space_platform_pre_mined,
  defines.events.on_entity_died,
  defines.events.script_raised_destroy,
}) do
  script.on_event(event_id, function(event) on_entity_changed(event, true) end)
end

-- Fires for every way a transformer can disappear (mined, destroyed, surface
-- deleted, ...)
script.on_event(defines.events.on_object_destroyed, function(event)
  if event.type == defines.target_type.entity and storage.transformers[event.useful_id] then
    unregister_transformer(event.useful_id)
  end
end)

-- Tick -------------------------------------------------------------------------------

script.on_event(defines.events.on_tick, function(event)
  local tick = event.tick
  update_line_losses(tick)
  update_transformers(tick)
  update_grid_diagram(tick)
  update_hover(tick)
  update_heatmap(tick)
  update_feed_paths(tick)
  update_transformer_panels(tick)
end)

-- Panel next to an opened transformer
script.on_event(defines.events.on_gui_opened, transformer_panel_on_opened)
script.on_event(defines.events.on_gui_closed, transformer_panel_on_closed)

-- Grid diagram toggle -----------------------------------------------------------

script.on_event("line-loss-toggle-grid-diagram", function(event)
  toggle_grid_diagram(game.get_player(event.player_index), event.tick)
end)
script.on_event("line-loss-toggle-heatmap", function(event)
  toggle_heatmap(game.get_player(event.player_index), event.tick)
end)
script.on_event("line-loss-toggle-feed-paths", function(event)
  toggle_feed_paths(game.get_player(event.player_index))
end)
script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "line-loss-toggle-grid-diagram" then
    toggle_grid_diagram(game.get_player(event.player_index), event.tick)
  elseif event.prototype_name == "line-loss-toggle-heatmap" then
    toggle_heatmap(game.get_player(event.player_index), event.tick)
  elseif event.prototype_name == "line-loss-toggle-feed-paths" then
    toggle_feed_paths(game.get_player(event.player_index))
  end
end)

script.on_event(defines.events.on_gui_location_changed, function(event)
  local element = event.element
  if element and element.valid then grid_diagram_on_moved(element, event.player_index) end
end)

-- Worst-routes list: "Show" opens the map at the route
script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  transformer_panel_on_checked(event)
end)

script.on_event(defines.events.on_gui_click, function(event)
  local element = event.element
  if element and element.valid then grid_diagram_on_click(element, game.get_player(event.player_index)) end
end)
