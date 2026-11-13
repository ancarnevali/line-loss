-- Machine load per pole (line loading views, kirchhoff.lua, overload by local load), and the
-- clean-up of map views removed in 0.2.0.

-- Load per pole for each owning transformer: weights per machine type, or
-- the even share
local function owner_load_info(parts, tick)
  local info = {}
  local pole_out = parts.pole_out
  if not (pole_out and pole_out.valid) then return info end
  if storage.settings.machine_weighting and parts.line_types then
    info.weights = machine_type_weights(pole_out, type_totals(parts.line_types), tick)
  end
  if not info.weights and (parts.line_n or 0) > 0 then
    info.even = get_network_loads(pole_out, tick).machines / parts.line_n
  end
  return info
end

-- Machine load on a pole, delivered by its owner (W): live weights per
-- machine type with machine weighting, else the network's machine load spread
-- evenly over the poles with a supply area. per_owner caches the owners' load
-- info for one pass.
function pole_machine_load(entry, per_owner, tick)
  local owner = entry.owner
  local parts = owner and storage.transformers[owner]
  if not parts then return 0 end
  local info = per_owner[owner]
  if not info then
    info = owner_load_info(parts, tick)
    per_owner[owner] = info
  end
  local load = 0
  if info.weights then
    for name, count in pairs(entry.m or {}) do
      local w = info.weights[name]
      if w then load = load + w * count end
    end
  elseif info.even and not entry.ns then
    load = info.even
  end
  return load
end

local function destroy(id)
  local object = id and rendering.get_object_by_id(id)
  if object and object.valid then object.destroy() end
end

-- Drawings of the line-loss map, the "power lost per pole" view and feed
-- paths (all replaced by the line loading views in 0.2.0)
function legacy_views_clear()
  if storage.loss_map then
    for _, dot in pairs(storage.loss_map.dots or {}) do destroy(dot.id) end
    storage.loss_map = nil
  end
  if storage.heatmap then
    for _, entry in pairs(storage.heatmap.poles or {}) do
      if entry.obj and entry.obj.valid then entry.obj.destroy() else destroy(entry.id) end
    end
    storage.heatmap = nil
  end
  local fp = storage.feed_paths
  if fp then
    for _, shown in pairs(fp.shown or {}) do
      for _, id in pairs(shown.ids or {}) do destroy(id) end
    end
    -- Power Overload drawings it hid are given back by the overlay
    storage.po_overlay = storage.po_overlay or {hidden = fp.po_hidden or {}, handled = {}}
    storage.feed_paths = nil
  end
end
