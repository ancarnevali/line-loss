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

-- Transmission poles: every pole (fuses and other mods' poles included) that
-- Power Overload rates at the big electric pole's rating or more carries power
-- only: no supply area. Their names say so; Kirchhoff flows (scripts/
-- kirchhoff.lua) run on them, the trees on everything else. Hidden poles are
-- left alone.
local rating = ratings.make_rating_lookup(shared, settings.startup, mods)
local reference = rating("big-electric-pole")
-- The big electric pole itself is left as it is (big poles already built keep
-- their supply area); it can no longer be crafted, and the upgrade planner
-- turns it into the big transmission pole.
local BIG, BIG_TRANSMISSION = "big-electric-pole", "line-loss-big-transmission-pole"
if data.raw["electric-pole"][BIG_TRANSMISSION] then
  for _, technology in pairs(data.raw.technology) do
    local effects = technology.effects
    if effects then
      for i = #effects, 1, -1 do
        if effects[i].type == "unlock-recipe" and effects[i].recipe == BIG then table.remove(effects, i) end
      end
    end
  end
  if data.raw.recipe[BIG] then data.raw.recipe[BIG].enabled, data.raw.recipe[BIG].hidden = false, true end
  -- (the item stays visible: an entity with next_upgrade may not mine into a
  -- hidden item)
  local big = data.raw["electric-pole"][BIG]
  if big then big.next_upgrade = BIG_TRANSMISSION end
end
if reference then
  for name, pole in pairs(data.raw["electric-pole"]) do
    local hidden = pole.hidden or name == BIG or name == "po-interface" or string.sub(name, 1, 10) == "po-hidden-"
    local w = not hidden and rating(name)
    if w and w >= reference then
      pole.supply_area_distance = 0
      pole.localised_description = {"line-loss.transmission-description"}
      -- One naming rule for all: "<base name> (transmission)". The big
      -- transmission pole takes the big electric pole's name as its base.
      local base = name == BIG_TRANSMISSION and {"entity-name." .. BIG} or pole.localised_name or {"entity-name." .. name}
      pole.localised_name = {"line-loss.transmission-name", base}
      for _, item in pairs(data.raw.item) do
        if item.place_result == name then item.localised_name = pole.localised_name end
      end
    end
  end
end

-- Crafting menu: an "Energy" tab, adapted from Energy Category by Lumme (MIT,
-- https://mods.factorio.com/mod/EnergyCategory; icon from it): energy items in
-- rows by what they do, with poles split into transmission and distribution
-- (each by rating, poles before their fuses) and a row for transformers. With
-- Energy Category installed, its tab and rows are used and only the poles and
-- transformers are sorted here.
do
  local raw = data.raw
  local ec = raw["item-group"] and raw["item-group"]["energy"] ~= nil
  local new = {}
  if not ec then
    new[#new + 1] = {type = "item-group", name = "energy", order = "ab-line-loss",
      icon = "__line-loss__/graphics/group/energy.png", icon_size = 128}
  end
  local rows = {
    {"energy-boiling", "a[boiling]"},
    {"energy-electricity-logistics", "b[electricity-logistics]"},
    {"energy-electricity-storage", "b[electricity-storage]"},
    {"energy-electricity", "b[electricity]"},
    {"energy-heating-logistics", "c[heating-logistics]"},
    {"energy-heating", "c[heating]"},
    {"energy-fusion", "e[fusion]"},
    {"line-loss-transmission", "b[electricity-logistics]-a[line-loss]-a"},
    {"line-loss-distribution", "b[electricity-logistics]-a[line-loss]-b"},
    {"line-loss-transformers", "b[electricity-logistics]-a[line-loss]-c"},
  }
  for _, row in ipairs(rows) do
    if not (raw["item-subgroup"] and raw["item-subgroup"][row[1]]) then
      new[#new + 1] = {type = "item-subgroup", name = row[1], group = "energy", order = row[2] .. "-line-loss"}
    end
  end
  data:extend(new)
  if not ec then
    local moves = {
      ["boiler"] = {"energy-boiling", "a"}, ["heat-exchanger"] = {"energy-boiling", "c-b"},
      ["solar-panel"] = {"energy-electricity", "b"}, ["steam-engine"] = {"energy-electricity", "c"},
      ["steam-turbine"] = {"energy-electricity", "d"}, ["lightning-rod"] = {"energy-electricity", "f-a"},
      ["lightning-collector"] = {"energy-electricity", "f-b"},
      ["accumulator"] = {"energy-electricity-storage", "a"},
      ["heat-pipe"] = {"energy-heating-logistics", "a-b"},
      ["nuclear-reactor"] = {"energy-heating", "g"}, ["heating-tower"] = {"energy-heating", "f-z"},
      ["fusion-reactor"] = {"energy-fusion", "e-y"}, ["fusion-generator"] = {"energy-fusion", "e-z"},
    }
    for name, move in pairs(moves) do
      local item = raw.item[name]
      if item then item.subgroup, item.order = move[1], move[2] end
    end
  end
  for _, item in pairs(raw.item) do
    local name = item.place_result
    local pole = name and raw["electric-pole"][name]
    if pole and not (pole.hidden or item.hidden) and name ~= "po-interface" and string.sub(name, 1, 10) ~= "po-hidden-" then
      local w = rating(name)
      if w and reference then
        item.subgroup = w >= reference and "line-loss-transmission" or "line-loss-distribution"
        item.order = string.format("%016.0f-%s", w, string.find(name, "fuse") and "b" or "a")
      end
    elseif name and raw["power-switch"] and raw["power-switch"][name]
        and string.sub(name, 1, 14) == "po-transformer" and not item.hidden then
      item.subgroup = "line-loss-transformers"
    end
  end
end
