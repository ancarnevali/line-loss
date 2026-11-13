-- Power Overload options Line loss needs, locked while Line loss is installed:
-- its own transformer efficiency at 1 (Line loss applies efficiency and core
-- loss) and "When power pole is overloaded" at Nothing (Line loss checks each
-- pole's local load instead).
local efficiency = (data.raw["double-setting"] or {})["power-overload-transformer-efficiency"]
if efficiency then
  efficiency.default_value = 1
  efficiency.allowed_values = {1}
  efficiency.localised_description = {"", {"mod-setting-description.power-overload-transformer-efficiency"},
    "\n\n", {"line-loss.po-efficiency-note"}}
end
local overload = (data.raw["string-setting"] or {})["power-overload-on-pole-overload"]
if overload then
  overload.default_value = "nothing"
  overload.allowed_values = {"nothing"}
  overload.localised_description = {"line-loss.po-overload-note"}
end
