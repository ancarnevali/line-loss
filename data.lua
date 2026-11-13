-- Hidden consumers that draw the losses, so they show up in the electric
-- network statistics. Placed by control.lua on Power Overload's hidden
-- transformer surface, next to Power Overload's own hidden interfaces:
--   "Line loss"      on the transformer's downstream network
--   "Transformer losses" on the transformer's upstream network

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
    buffer_capacity = "1MJ",  -- resized by script to fit the loss drawn
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

local line_consumer = consumer("line-loss-line-consumer")
-- Shown with the big pole's icon in the electric network statistics, so line
-- losses are easy to tell apart from the transformer's own losses
line_consumer.icons = {{icon = "__base__/graphics/icons/big-electric-pole.png", icon_size = 64}}
line_consumer.icon = nil

data:extend{
  line_consumer,
  consumer("line-loss-ineff-consumer"),
}

-- Map views (shortcut bar + optional key bindings)
local function view(name, icon, order)
  return {
    {
      type = "shortcut",
      name = name,
      localised_description = {"shortcut-description." .. name},
      action = "lua",
      associated_control_input = name,
      toggleable = true,
      order = "c[toggles]-h[" .. order .. "]",
      icon = "__line-loss__/graphics/shortcuts/" .. icon .. "-x32.png",
      icon_size = 32,
      small_icon = "__line-loss__/graphics/shortcuts/" .. icon .. "-x24.png",
      small_icon_size = 24,
    },
    {
      type = "custom-input",
      name = name,
      localised_name = {"shortcut-name." .. name},
      key_sequence = "",
      consuming = "none",
      order = order,
    },
  }
end
data:extend(view("line-loss-toggle-line-loading", "line-loading", "a"))
data:extend(view("line-loss-toggle-line-loading-rated", "line-loading-rated", "b"))
data:extend(view("line-loss-toggle-losses", "losses", "c"))
data:extend(view("line-loss-toggle-networks", "networks", "d"))
require("__line-loss__/prototypes/big-transmission-pole")
require("__line-loss__/prototypes/compact-substation")
