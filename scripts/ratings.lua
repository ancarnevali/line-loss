-- Pole power ratings (W, normal quality) from Power Overload's startup
-- settings, and the line resistance derived from them. Works in both the data
-- and the control stage. Everything here is derived from startup settings and
-- active mods, so it is the same on every client and never needs saving.

local REFERENCE_POLE = "big-electric-pole"

local ratings = {}

---@param shared table   Power Overload's shared.lua
---@param startup table  settings.startup
---@param mods table     mods (data stage) or script.active_mods (control stage)
---@return fun(prototype_name: string): number?  resistance per tile (big pole = 1), nil if unrated
function ratings.make_resistance_lookup(shared, startup, mods)
  local aliases = (shared.get_pole_aliases and shared.get_pole_aliases()) or {}
  -- A fuse is the same line as its pole, so it uses its pole's rating rather
  -- than its own (fuses are rated lower so that they blow first).
  local fuse_to_pole = {}
  if shared.get_poles_to_make_fuses and shared.get_name_for_fuse and shared.get_prototype_name_for_pole then
    for _, pole_name in pairs(shared.get_poles_to_make_fuses(mods)) do
      fuse_to_pole[shared.get_name_for_fuse(pole_name)] = shared.get_prototype_name_for_pole(pole_name)
    end
  end

  local function rating(prototype_name)
    local name = fuse_to_pole[prototype_name] or prototype_name
    local setting = startup["power-overload-max-power-" .. (aliases[name] or name)]
    local value = setting and setting.value
    if type(value) ~= "string" then return nil end
    local ok, watts = pcall(shared.validate_and_parse_energy, value, true)
    if ok and type(watts) == "number" and watts > 0 then return watts end
    return nil
  end

  ratings.last_rating = rating  -- raw W lookup, see make_rating_lookup
  local reference = rating(REFERENCE_POLE)
  local cache = {}
  return function(prototype_name)
    local r = cache[prototype_name]
    if r == nil then
      local own = reference and rating(prototype_name)
      -- r = sqrt(P_ref / P_pole): a pole rated for 30x less power has ~5.5x
      -- the resistance per tile
      r = own and math.sqrt(reference / own) or false
      cache[prototype_name] = r
    end
    return r or nil
  end
end

-- Rated power (W, normal quality) of a pole prototype, from Power Overload's
-- settings; fuses use their pole's rating. nil if unrated.
---@return fun(prototype_name: string): number?
function ratings.make_rating_lookup(shared, startup, mods)
  ratings.make_resistance_lookup(shared, startup, mods)
  local rating = ratings.last_rating
  local cache = {}
  return function(prototype_name)
    local w = cache[prototype_name]
    if w == nil then
      w = rating(prototype_name) or false
      cache[prototype_name] = w
    end
    return w or nil
  end
end

return ratings
