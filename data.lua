-- Hidden consumers that burn the losses, so they show up in the electric
-- network statistics. Placed by control.lua on Power Overload's hidden
-- transformer surface, next to Power Overload's own hidden interfaces:
--   "Line loss"      on the transformer's output network
--   "Transf. ineff." on the transformer's input network

local template = data.raw["electric-energy-interface"]["po-transformer-interface-hidden-in"]

local function consumer(name)
  local prototype
  if template then
    prototype = table.deepcopy(template)
  else
    prototype = {
      type = "electric-energy-interface",
      hidden = true,
      icon = "__base__/graphics/icons/power-switch.png",
      collision_mask = {layers = {}},
      flags = {"not-on-map", "not-blueprintable", "not-deconstructable", "hide-alt-info",
               "not-flammable", "not-repairable", "not-upgradable", "no-copy-paste", "placeable-off-grid"},
    }
  end
  prototype.name = name
  prototype.localised_name = {"entity-name." .. name}
  prototype.localised_description = nil
  prototype.energy_source = {
    type = "electric",
    buffer_capacity = "1MJ",  -- resized by script to fit the burn rate
    usage_priority = "secondary-input",
    input_flow_limit = "1YJ",
    output_flow_limit = "0J",
    render_no_network_icon = false,
    render_no_power_icon = false,
  }
  prototype.energy_production = "0W"
  prototype.energy_usage = "0W"  -- set by script
  prototype.gui_mode = "none"
  prototype.minable = nil
  return prototype
end

data:extend{
  consumer("line-loss-line-consumer"),
  consumer("line-loss-ineff-consumer"),
}

-- Grid diagram and heatmap toggles (shortcut bar + optional key bindings)
data:extend{
  {
    type = "shortcut",
    name = "line-loss-toggle-grid-diagram",
    action = "lua",
    associated_control_input = "line-loss-toggle-grid-diagram",
    toggleable = true,
    order = "c[toggles]-h[grid-diagram]",
    icon = "__line-loss__/graphics/shortcuts/grid-diagram-x32.png",
    icon_size = 32,
    small_icon = "__line-loss__/graphics/shortcuts/grid-diagram-x24.png",
    small_icon_size = 24,
  },
  {
    type = "shortcut",
    name = "line-loss-toggle-heatmap",
    localised_description = {"shortcut-description.line-loss-toggle-heatmap"},
    action = "lua",
    associated_control_input = "line-loss-toggle-heatmap",
    toggleable = true,
    order = "c[toggles]-h[grid-heatmap]",
    icon = "__line-loss__/graphics/shortcuts/heatmap-x32.png",
    icon_size = 32,
    small_icon = "__line-loss__/graphics/shortcuts/heatmap-x24.png",
    small_icon_size = 24,
  },
  {
    type = "shortcut",
    name = "line-loss-toggle-loss-map",
    localised_description = {"shortcut-description.line-loss-toggle-loss-map"},
    action = "lua",
    associated_control_input = "line-loss-toggle-loss-map",
    toggleable = true,
    order = "c[toggles]-h[grid-loss-map]",
    icon = "__line-loss__/graphics/shortcuts/loss-map-x32.png",
    icon_size = 32,
    small_icon = "__line-loss__/graphics/shortcuts/loss-map-x24.png",
    small_icon_size = 24,
  },
  {
    type = "custom-input",
    name = "line-loss-toggle-loss-map",
    localised_name = {"shortcut-name.line-loss-toggle-loss-map"},
    key_sequence = "",
    consuming = "none",
    order = "e",
  },
  {
    type = "custom-input",
    name = "line-loss-toggle-heatmap",
    localised_name = {"shortcut-name.line-loss-toggle-heatmap"},
    key_sequence = "",
    consuming = "none",
    order = "d",
  },
  {
    type = "custom-input",
    name = "line-loss-toggle-grid-diagram",
    localised_name = {"shortcut-name.line-loss-toggle-grid-diagram"},
    key_sequence = "",
    consuming = "none",
    order = "c",
  },
}
