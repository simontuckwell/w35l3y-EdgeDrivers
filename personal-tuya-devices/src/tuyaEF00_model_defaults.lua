local log = require "log"
local utils = require "st.utils"

local capabilities = require "st.capabilities"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local device_lib = require "st.device"

local tuyaEF00_defaults = require "tuyaEF00_defaults"
local myutils = require "utils"

local REPORT_BY_DP = {}

local mt = {}
mt.__cache = {}
mt.__index = function(self, model)
  if mt.__cache[model] == nil then
    log.info("Model cached", model)
    mt.__cache[model] = {}
    local mt_model = {}
    mt_model.__cache = {}
    mt_model.__index = function (self, manufacturer)
      if mt_model.__cache[manufacturer] == nil then
        log.info("Manufacturer cached", manufacturer)
        local ok, result = pcall(myutils.load_model_from_json, model, manufacturer)
        mt_model.__cache[manufacturer] = ok and result or {
          default = true
        }
        if not ok then
          log.error(result)
        end
      end
      return mt_model.__cache[manufacturer]
    end
    setmetatable(mt.__cache[model], mt_model)
  end
  return mt.__cache[model]
end
setmetatable(REPORT_BY_DP, mt)

local function get_default_by_profile (device, warn)
  for model, devices in pairs(mt.__cache) do
    for mfr, dp in pairs(devices) do
      for _, profile in ipairs(dp.profiles) do
        if myutils.is_profile(device, profile, mfr) then
          if warn then
            log.warn("Simulating device", model, mfr)
          end
          return dp
        end
      end
    end
  end
end
local function send_command(fn, driver, device, ...)
  local dp = REPORT_BY_DP[device:get_model()][device:get_manufacturer()]
  if dp == nil or dp.default then
    dp = get_default_by_profile(device, true)
  end
  if dp then
    fn(dp.datapoints)(driver, device, ...)
  end
end

local lifecycle_handlers = utils.merge({}, require "lifecycles")

function lifecycle_handlers.added(driver, device, event, ...)
  if device.network_type == device_lib.NETWORK_TYPE_ZIGBEE then
    -- device:send(zcl_clusters.TuyaEF00.commands.McuSyncTime(device))
    device.thread:call_with_delay(15, function()
      log.debug("--- GatewayData -----------------------------------")
      device:send(zcl_clusters.TuyaEF00.commands.GatewayData(device))
    end)
    
    -- local dp = REPORT_BY_DP[device:get_model()][device:get_manufacturer()]
    -- -- if dp == nil or dp.default then
    -- --   dp = get_default_by_profile(device, true)
    -- -- end

    -- log.info("ADDED", device:get_model(), device:get_manufacturer(), utils.stringify_table(dp and dp.added, "table", true))
    -- if dp and dp.added then
    --   for i, action in ipairs(dp.added) do
    --     log.info("Emit", action.capability, action.attribute)
    --     device:emit_event(capabilities[action.capability][action.attribute](action.value))
    --   end
    -- end
  end
end

local map_pref_to_child = {
  _temp_mea = "_temperatureMeasurement",
  _rel_hum_mea = "_relativeHumidityMeasurement",
  _contact_sensor = "_contactSensor",
}

function lifecycle_handlers.infoChanged(driver, device, event, args)
  if args.old_st_store.preferences.profile ~= device.preferences.profile or (not myutils.is_normal(device) and device.profile.components.main == nil) then
    log.debug("Profile changed...", args.old_st_store.preferences.profile, device.preferences.profile)
    device:try_update_metadata({
      profile = device.preferences.profile:gsub("_", "-")
    })
  end
  if args.old_st_store.preferences.timezoneOffset ~= device.preferences.timezoneOffset then
    log.debug("Timezone changed...", args.old_st_store.preferences.timezoneOffset, device.preferences.timezoneOffset)
    log.debug("It will need to wait the next request from the device as we don't have 'transid'")
    -- device:send(zcl_clusters.TuyaEF00.commands.McuSyncTime(device))
  end
  
  if device.network_type == device_lib.NETWORK_TYPE_ZIGBEE then
    for name, value in utils.pairs_by_key(device.preferences) do
      if value and args.old_st_store.preferences[name] ~= value then
        log.debug("Preference changed...", name, args.old_st_store.preferences[name], value)
        local normalized_id = utils.snake_case(name)
        local match, _length, pref, component, group = string.find(normalized_id, "^child(_?[%w_]*)_(main(%x+))$")
        log.debug("Is it child?", match, pref, component, group, normalized_id)
        if match then
          local profile = ("child" .. (pref ~= "" and map_pref_to_child[pref] or pref or "_switch") .. "-v1"):gsub("_", "-")
          myutils.create_child(driver, device, tonumber(group, 16), profile)
          goto next
        end
        local match, _length, key = string.find(normalized_id, "^pref_([%w_]+)$")
        log.debug("Is it settings?", match, key, normalized_id)
        if match then
          send_command(tuyaEF00_defaults.update_data, driver, device, key, value)
          goto next
        end
      end
      ::next::
    end
  else
    for name, value in utils.pairs_by_key(device.preferences) do
      if value ~= nil and args.old_st_store.preferences[name] ~= value then
        log.debug("Preference changed...", name, args.old_st_store.preferences[name], value)
      end
    end
  end
end

local defaults = {
  lifecycle_handlers = lifecycle_handlers,
  command_synctime_handler = tuyaEF00_defaults.command_synctime_handler,
  command_gatestatus_handler = tuyaEF00_defaults.command_gatestatus_handler,
  fallback_handler = function (driver, device, zb_rx)
    log.debug("MODEL FALLBACK", zb_rx:pretty_print())
  end,
}

function defaults.can_handle (opts, driver, device, ...)
  if myutils.is_profile(device, "generic_ef00_v1") or myutils.is_profile(device, "normal_multi_switch_v1") or myutils.is_profile(device, "normal_multi_dimmer_v1") then
    return false
  end
  -- log.info(device:get_model(), device:get_manufacturer())
  local x = REPORT_BY_DP[device:get_model()][device:get_manufacturer()]
  if x and x.default == nil then
    -- `default == nil` means a profile was found for the model+mfr
    return true
  end
  mt.__cache = require "models"
  local prf = get_default_by_profile(device, false)
  if prf then
    return true
  elseif device.parent_assigned_child_key then
    log.warn("Similar device not found (child)", device:get_model(), device:get_manufacturer(), device.preferences.profile, device:get_parent_device().preferences.profile)
  elseif device.preferences.profile then
    log.warn("Similar device not found (parent)", device:get_model(), device:get_manufacturer(), device.preferences.profile)
  end
  return false
end

function defaults.command_response_handler(...)
  send_command(tuyaEF00_defaults.command_response_handler, ...)
end

function defaults.capability_handler(...)
  send_command(tuyaEF00_defaults.capability_handler, ...)
end

function defaults.register_for_default_handlers(driver, capabilities)
  driver.capability_handlers = driver.capability_handlers or {}

  for _,cap in ipairs(capabilities) do
    driver.capability_handlers[cap.ID] = driver.capability_handlers[cap.ID] or {}
    for _,command in pairs(cap.commands) do
      driver.capability_handlers[cap.ID][command.NAME] = driver.capability_handlers[cap.ID][command.NAME] or defaults.capability_handler
    end
  end
end

return defaults