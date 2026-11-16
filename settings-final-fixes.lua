-- Huge electric pole rated 1 GW (Power Overload's default is higher), locked
-- while Line loss is installed. Power Overload creates the setting in its own
-- settings-final-fixes, which runs before this one.
local huge = (data.raw["string-setting"] or {})["power-overload-max-power-po-huge-electric-pole"]
if huge then
  huge.default_value = "1GW"
  huge.allowed_values = {"1GW"}
  huge.localised_description = {"line-loss.po-huge-note"}
end
