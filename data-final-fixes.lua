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

-- Power Overload's high- and low-priority transformers are hidden: their
-- output priority makes them supply first or last, while this mod splits a
-- network's supply among its transformers as if they shared the load. Their
-- recipes are taken out of the technologies and disabled; transformers already
-- built keep working.
local PRIORITY_TRANSFORMERS = {["po-transformer-high"] = true, ["po-transformer-low"] = true}

for _, technology in pairs(data.raw.technology) do
  local effects = technology.effects
  if effects then
    for i = #effects, 1, -1 do
      local effect = effects[i]
      if effect.type == "unlock-recipe" and PRIORITY_TRANSFORMERS[effect.recipe] then
        table.remove(effects, i)
      end
    end
  end
end

for name in pairs(PRIORITY_TRANSFORMERS) do
  local recipe = data.raw.recipe[name]
  if recipe then
    recipe.enabled = false
    recipe.hidden = true
  end
  local item = data.raw.item[name]
  if item then
    item.hidden = true
  end
  local entity = data.raw["electric-pole"][name] or data.raw["power-switch"][name]
  if entity then
    entity.hidden_in_factoriopedia = true
  end
end
