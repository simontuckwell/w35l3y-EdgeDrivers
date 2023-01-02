--local log = require "log"
--local utils = require "st.utils"

local capabilities = require "st.capabilities"
local zcl_clusters = require "st.zigbee.zcl.clusters"

return {
  NAME = "Signal Strength",
  can_handle = function (opts, driver, device, ...)
    return device:supports_capability_by_id(capabilities.signalStrength.ID)
  end,
  supported_capabilities = {
    capabilities.signalStrength,
  },
  zigbee_handlers = {
    attr = {
      [zcl_clusters.Basic.ID] = {
        [zcl_clusters.Basic.attributes.ZCLVersion.ID] = function(driver, device, value, zb_rx)
          device:emit_event(capabilities.signalStrength.rssi({value=zb_rx.rssi.value}))
          device:emit_event(capabilities.signalStrength.lqi({value=zb_rx.lqi.value}))
        end,
      },
    },
  },
}