-- "Line resistance" row in every rated pole's tooltip (after all mods have
-- added their poles). Resistance per tile of wire, relative to the big
-- electric pole; fuses show their pole's value. Normal quality.

if not util then util = require("util") end  -- shared.lua uses the global util
local shared = require("__PowerOverload__/shared")
local ratings = require("__line-loss__/scripts/ratings")

local resistance = ratings.make_resistance_lookup(shared, settings.startup, mods)

for prototype_name, prototype in pairs(data.raw["electric-pole"]) do
  if prototype_name ~= "po-interface" and string.sub(prototype_name, 1, 10) ~= "po-hidden-" then
    local r = resistance(prototype_name)
    if r then
      prototype.custom_tooltip_fields = prototype.custom_tooltip_fields or {}
      table.insert(prototype.custom_tooltip_fields, {
        name = {"description.line-loss-resistance"},
        value = string.format("%.2g", r) .. "×",
        order = 151,
      })
    end
  end
end
