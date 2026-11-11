-- Big transmission pole: a big electric pole with no supply area. It only
-- carries power, so machine load is never spread over it, and it can run
-- past factories without powering them. Same reach, health, recipe and
-- Power Overload rating (300 MW, registered in settings.lua) as the big pole;
-- tinted so the two can be told apart.

local NAME = "line-loss-big-transmission-pole"
local TINT = {r = 0.72, g = 0.84, b = 1.0}

local base = data.raw["electric-pole"]["big-electric-pole"]
if not base then return end

local pole = table.deepcopy(base)
pole.name = NAME
pole.localised_name = nil
pole.localised_description = nil
pole.supply_area_distance = 0
pole.minable = {mining_time = (base.minable and base.minable.mining_time) or 0.1, result = NAME}
pole.next_upgrade = nil
pole.icons = {{icon = base.icon or "__base__/graphics/icons/big-electric-pole.png", icon_size = base.icon_size or 64, tint = TINT}}
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

local item = table.deepcopy(data.raw.item["big-electric-pole"])
item.name = NAME
item.place_result = NAME
item.icons = pole.icons
item.icon = nil
item.order = (item.order or "a[energy]-c[big-electric-pole]") .. "-a[transmission]"

local recipe = table.deepcopy(data.raw.recipe["big-electric-pole"])
recipe.name = NAME
recipe.results = {{type = "item", name = NAME, amount = 1}}
recipe.main_product = nil

data:extend{pole, item, recipe}

-- Unlocked together with the big electric pole
for _, technology in pairs(data.raw.technology) do
  for _, effect in pairs(technology.effects or {}) do
    if effect.type == "unlock-recipe" and effect.recipe == "big-electric-pole" then
      table.insert(technology.effects, {type = "unlock-recipe", recipe = NAME})
      break
    end
  end
end
