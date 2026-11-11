-- Rate the big transmission pole like the big electric pole in Power Overload
-- (and so in this mod's resistance and core-loss ratings)
require("__PowerOverload__/registry")
PowerOverload.register_pole{name = "line-loss-big-transmission-pole", default = "300MW"}

data:extend{
  {
    type = "bool-setting",
    name = "line-loss-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "a"
  },
  {
    type = "double-setting",
    name = "line-loss-per-tile",
    setting_type = "runtime-global",
    default_value = 0.025,
    minimum_value = 0,
    maximum_value = 1,
    order = "b"
  },
  {
    type = "bool-setting",
    name = "line-loss-closeness",
    setting_type = "runtime-global",
    default_value = true,
    order = "c"
  },
  {
    type = "double-setting",
    name = "line-loss-transformer-efficiency",
    setting_type = "runtime-global",
    default_value = 0.99,
    minimum_value = 0.01,
    maximum_value = 1,
    order = "d"
  },
  {
    type = "double-setting",
    name = "line-loss-no-load",
    setting_type = "runtime-global",
    default_value = 0.1,
    minimum_value = 0,
    maximum_value = 5,
    order = "e"
  },
  {
    type = "bool-setting",
    name = "line-loss-machine-weighting",
    setting_type = "runtime-global",
    default_value = false,
    order = "ca"
  },
  {
    type = "bool-setting",
    name = "line-loss-show-idle-routes",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "z"
  },
  {
    type = "bool-setting",
    name = "line-loss-show-loss-check",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "zb"
  },
  {
    type = "bool-setting",
    name = "line-loss-panel-same-unit",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "za"
  },
}
