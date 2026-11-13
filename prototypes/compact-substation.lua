-- Compact substation: a substation (same reach, rating 125 MW, recipe) with a
-- medium pole's supply area. A distribution pole for trunk lines inside a
-- factory: it carries a substation's power but powers only the area around it
-- a medium pole would. Tinted so it can be told from the substation.

local NAME = "line-loss-compact-substation"
local TINT = {r = 1.0, g = 0.86, b = 0.62}

local base = data.raw["electric-pole"]["substation"]
if not base then return end
local medium = data.raw["electric-pole"]["medium-electric-pole"]

local pole = table.deepcopy(base)
pole.name = NAME
pole.localised_name = nil
pole.localised_description = nil
pole.supply_area_distance = medium and medium.supply_area_distance or 3.5
pole.minable = {mining_time = (base.minable and base.minable.mining_time) or 0.1, result = NAME}
pole.next_upgrade = nil
pole.icons = {{icon = base.icon or "__base__/graphics/icons/substation.png", icon_size = base.icon_size or 64, tint = TINT}}
pole.icon = nil

-- Tint every picture layer except the shadow
local function tint_layers(sprite)
  if type(sprite) ~= "table" then return end
  if sprite.layers then
    for _, layer in pairs(sprite.layers) do tint_layers(layer) end
  elseif sprite.filename or sprite.filenames or sprite.stripes then
    if not sprite.draw_as_shadow then sprite.tint = TINT end
  end
end
tint_layers(pole.pictures)

local item = table.deepcopy(data.raw.item["substation"])
item.name = NAME
item.place_result = NAME
item.icons = pole.icons
item.icon = nil
item.order = (item.order or "a[energy]-d[substation]") .. "-b[compact]"

local recipe = table.deepcopy(data.raw.recipe["substation"])
recipe.name = NAME
recipe.results = {{type = "item", name = NAME, amount = 1}}
recipe.main_product = nil

data:extend{pole, item, recipe}

-- Unlocked together with the substation
for _, technology in pairs(data.raw.technology) do
  for _, effect in pairs(technology.effects or {}) do
    if effect.type == "unlock-recipe" and effect.recipe == "substation" then
      table.insert(technology.effects, {type = "unlock-recipe", recipe = NAME})
      break
    end
  end
end
