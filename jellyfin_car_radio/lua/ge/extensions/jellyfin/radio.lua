local M = {}

-- === Configuration ===

local CONFIG_TEMPLATE = [[{
  "server_url": "http://127.0.0.1:8096",
  "api_key": "your-api-key-here"
}
]]

local CONFIG_DIR = 'settings/jellyfin_car_radio/'
local CONFIG_PATH = CONFIG_DIR .. 'config.json'
local CACHE_DIR = CONFIG_DIR .. 'cache/'

local cfg = nil      -- validated config table, or nil while disabled
local enabled = false

-- === Small Helpers ===

local TAG = 'JellyfinRadio'
local function logI(msg) log('I', TAG, '[JellyfinRadio] ' .. msg) end
local function logW(msg) log('W', TAG, '[JellyfinRadio] ' .. msg) end
local function logE(msg) log('E', TAG, '[JellyfinRadio] ' .. msg) end

local function urlEncode(s)
  return (tostring(s or ''):gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

local function radioVolume()
  return settings.getValue('AudioMasterVol') * settings.getValue('AudioMusicVol')
end

-- === Config Loading ===

local function parseServerUrl(url)
  local scheme, host, port = tostring(url or ''):match('^(%a+)://([^:/]+):?(%d*)')
  return scheme, host, (port ~= '' and tonumber(port)) or nil
end

local function writeDefaultConfig()
  FS:directoryCreate(CONFIG_DIR, true)
  local f = io.open(CONFIG_PATH, 'w')
  if not f then return false end
  f:write(CONFIG_TEMPLATE)
  f:close()
  return true
end

local function loadConfig()
  if not FS:fileExists(CONFIG_PATH) then
    if writeDefaultConfig() then
      logE('no config found; created ' .. CONFIG_PATH .. ' - add your api_key and restart the game')
    else
      logE('no config found and could not create ' .. CONFIG_PATH)
    end
    return nil
  end
  local ok, raw = pcall(function() return jsonReadFile and jsonReadFile(CONFIG_PATH) end)
  if not ok or type(raw) ~= 'table' then
    logE('config missing or malformed at ' .. CONFIG_PATH .. ' - mod disabled')
    return nil
  end

  local scheme, host, port = parseServerUrl(raw.server_url)
  if scheme ~= 'http' then
    logE('server_url must be a plain http:// URL (got ' .. tostring(raw.server_url) ..
      ') - TLS and non-http schemes are not supported. Mod disabled.')
    return nil
  end
  host = host and host:lower()
  if host ~= '127.0.0.1' and host ~= 'localhost' then
    logW('server_url is not a loopback (got ' ..
      tostring(raw.server_url) .. ') - REALLY make sure your sandbox settings permit this!')
  end
  if type(raw.api_key) ~= 'string' or raw.api_key == '' then
    logE('config.json is missing api_key - mod disabled')
    return nil
  end

  return {
    host = host,
    port = port or 8096,
    apiKey = raw.api_key,
    keepCache = raw.keep_cache or false
  }
end

-- === CEF / Web Audio Bridge ===
--
-- Manages HTML5 audio streaming and digital signal processing within the CEF UI thread.
--
-- Exposes JS bindings to Lua for controlling playback lifecycle, volume, and audio graph transformations.
--
-- TODO: Expand audio graph capabilities for doppler, room, and EQ

local function loadBridgeJS()
  local f = io.open('ui/jellyfin_radio/bridge.js', 'r')
  if not f then return '' end
  local content = f:read('*all')
  f:close()
  return content
end

local bridgeJS = loadBridgeJS()

local function js(fmt, ...)
  be:queueJS(string.format(fmt, ...))
end

-- === HTTP Client ===
--
-- Avoids blocking the main game thread by reading socket data incrementally during each onUpdate frame. 
--
-- To avoid the extreme memory reallocation overhead (O(n^2)) of concatenating megabytes of data into a single Lua string, audio files are written directly to the disk in chunks as they arrive.

local READS_PER_FRAME = 8
local READ_SIZE = 8192
local CONNECT_DEADLINE = 3
local REQUEST_DEADLINE = { meta = 10, audio = 60 }

local request = nil

local function readSocket(sock)
  local out, closed = {}, false
  for _ = 1, READS_PER_FRAME do
    local data, err, partial = sock:receive(READ_SIZE)
    local got = data or partial
    if got and #got > 0 then out[#out + 1] = got end
    if err and err ~= 'timeout' then closed = true break end
    if not got or #got < READ_SIZE then break end
  end
  return table.concat(out), closed
end

local function parseHeaders(raw)
  local h = {}
  for line in raw:gmatch('[^\r\n]+') do
    local k, v = line:match('^([^:]+):%s*(.*)$')
    if k then h[k:lower()] = v end
  end
  return h
end

local function cancelRequest()
  if not request then return end
  local r = request
  request = nil
  pcall(function() r.sock:close() end)
  if r.fileHandle then pcall(function() r.fileHandle:close() end) end
  if r.toFile then pcall(function() os.remove(r.toFile) end) end
end

local function finishRequest()
  local r = request
  request = nil
  pcall(function() r.sock:close() end)
  if r.fileHandle then pcall(function() r.fileHandle:close() end) end
  if r.status ~= 200 then
    if r.toFile then pcall(function() os.remove(r.toFile) end) end
    r.onError(string.format('Jellyfin answered HTTP %s', tostring(r.status)))
    return
  end
  if r.toFilePrefix then
    r.onDone(r.toFile)
  else
    local ok, parsed = pcall(jsonDecode, table.concat(r.bodyChunks or {}))
    if not ok or type(parsed) ~= 'table' then
      r.onError('could not parse JSON from Jellyfin')
      return
    end
    r.onDone(parsed)
  end
end

local function failRequest(msg)
  local r = request
  request = nil
  if not r then return end
  pcall(function() r.sock:close() end)
  if r.fileHandle then pcall(function() r.fileHandle:close() end) end
  if r.toFile then pcall(function() os.remove(r.toFile) end) end
  r.onError(msg)
end

local function startRequest(path, kind, opts)
  cancelRequest()  -- (a skip cancels whatever was in flight)
  local sock = socket.tcp()
  sock:settimeout(0)
  local ok, err = sock:connect(cfg.host, cfg.port)
  if not ok and err ~= 'timeout' then
    pcall(function() sock:close() end)
    opts.onError('could not connect to Jellyfin: ' .. tostring(err))
    return
  end
  local authHeader = string.format(
    'Authorization: MediaBrowser Token="%s", Client="JellyfinCarRadio", ' ..
    'Device="BeamNG.drive", DeviceId="jellyfin-car-radio", Version="1.0"',
    cfg.apiKey)
  request = {
    sock = sock, kind = kind, head = '', inBody = false, age = 0, bytesGot = 0,
    connecting = true,
    connectStart = socket.gettime(),
    payload = 'GET ' .. path .. ' HTTP/1.0\r\nHost: ' .. cfg.host ..
      '\r\nUser-Agent: JellyfinCarRadio\r\n' .. authHeader ..
      '\r\nConnection: close\r\n\r\n',
    toFilePrefix = opts.toFilePrefix, toFile = nil,
    onDone = opts.onDone, onError = opts.onError,
  }
end

local function pumpRequest(dt)
  if not request then return end
  local r = request
  r.age = r.age + (dt or 0)
  if r.connecting then
    if r.sock:getpeername() then
      r.connecting = false
      r.sock:send(r.payload)
    elseif socket.gettime() - r.connectStart > CONNECT_DEADLINE then
      failRequest('timed out connecting to Jellyfin')
      return
    else
      return
    end
  end
  local data, closed = readSocket(r.sock)
  if data and #data > 0 then
    if not r.inBody then
      r.head = r.head .. data
      local cut = r.head:find('\r\n\r\n', 1, true)
      if cut then
        local rawHeaders = r.head:sub(1, cut - 1)
        local rest = r.head:sub(cut + 4)
        r.headers = parseHeaders(rawHeaders)
        r.status = tonumber(rawHeaders:match('^HTTP/%d%.%d (%d+)'))
        r.contentLength = tonumber(r.headers['content-length'] or '')
        if r.headers['transfer-encoding']
           and r.headers['transfer-encoding']:lower():find('chunked', 1, true) then
          failRequest('Jellyfin sent a chunked response, which this mod does not parse')
          return
        end
        r.inBody = true
        r.head = nil
        if r.toFilePrefix then
          local mime = ((r.headers['content-type'] or ''):match('^[^;]+') or ''):lower()
          r.toFile = r.toFilePrefix
          r.fileHandle = io.open(r.toFile, 'wb')
          if not r.fileHandle then
            failRequest('could not open cache file for writing: ' .. r.toFile)
            return
          end
          if #rest > 0 then r.fileHandle:write(rest) end
        else
          r.bodyChunks = { rest }
        end
        r.bytesGot = #rest
      end
    else
      r.bytesGot = r.bytesGot + #data
      if r.toFilePrefix then r.fileHandle:write(data)
      else table.insert(r.bodyChunks, data) end
    end
  end
  local done = closed or (r.contentLength and r.bytesGot >= r.contentLength)
  if done then
    finishRequest()
  elseif r.age > (REQUEST_DEADLINE[r.kind] or 20) then
    failRequest('Jellyfin did not finish answering in time')
  end
end

-- === Jellyfin API ===

local function fetchRandomItem(onDone, onError)
  local path = '/Items?IncludeItemTypes=Audio&Recursive=true&SortBy=Random&Limit=1'
  startRequest(path, 'meta', {
    onDone = function(parsed)
      local item = parsed.Items and parsed.Items[1]
      if not item or not item.Id then
        onError('Jellyfin returned no audio items (is the library empty?)')
        return
      end
      onDone(item.Id, item.Name or item.Id, tonumber(item.NormalizationGain))
    end,
    onError = onError,
  })
end

local function downloadItem(itemId, onDone, onError)
  local path = string.format('/Audio/%s/stream?static=true', urlEncode(itemId))
  FS:directoryCreate(CACHE_DIR, true)
  startRequest(path, 'audio', {
    toFilePrefix = CACHE_DIR .. itemId,
    onDone = onDone,
    onError = onError,
  })
end

-- === State Machine ===

local phase = 'idle'  -- idle | fetching | playing | waiting_retry
local currentItemId, currentItemName, currentPath = nil, nil, nil
local retryTimer, retryDelay = 0, 5
local RETRY_BASE, RETRY_MAX = 5, 30
local posTimer = 0
local hadVehicle = false
local nextItem = nil

local function hasVehicle()
  local veh = be:getPlayerVehicle(0)
  if not veh then return false end
  -- (explanation: the character "vehicle" is a "unicycle")
  if veh.getJBeamFilename and veh:getJBeamFilename() == 'unicycle' then return false end
  return true
end

local function stopPlayback()
  js('if(window._jfRadio)window._jfRadio.stop();')
end

local function cleanupCurrentCache()
  if currentPath and not cfg.keepCache then
    local ok, err = pcall(function() os.remove(currentPath) end)
    if not ok then logW('could not remove cache file ' .. currentPath .. ': ' .. tostring(err)) end
  end
  currentPath, currentItemId, currentItemName = nil, nil, nil
end

local function bumpRetryDelay() retryDelay = math.min(RETRY_MAX, retryDelay * 2) end
local function resetRetryDelay() retryDelay = RETRY_BASE end

local function scheduleRetry(reason)
  logW(reason .. ' - retrying in ' .. retryDelay .. 's')
  phase = 'waiting_retry'
  retryTimer = 0
end

-- Download a random track
local function fetchTrack(onReady, onFail)
  fetchRandomItem(function(id, name, gainDb)
    if id == currentItemId then return onFail('same track as current') end
    downloadItem(id, function(path)
      onReady({ id = id, name = name, gainDb = gainDb, path = path })
    end, onFail)
  end, onFail)
end

local function playItem(it)
  currentItemId, currentItemName, currentPath = it.id, it.name, it.path
  resetRetryDelay()
  local uiPath = it.path:sub(1, 1) == '/' and it.path or ('/' .. it.path)
  be:queueJS(bridgeJS)
  js("window._jfRadio.play('%s',%f,%f);", uiPath:gsub("'", "\\'"), radioVolume(), it.gainDb or 0)
  phase = 'playing'
  logI(string.format('playing: %s (normalization gain %s dB)', tostring(it.name), tostring(it.gainDb)))
  fetchTrack(function(n) nextItem = n end,
             function(msg) logW('prefetch failed: ' .. tostring(msg)) end)
end

local function startFetch()
  if nextItem then
    local it = nextItem
    nextItem = nil
    playItem(it)
    return
  end
  phase = 'fetching'
  fetchTrack(playItem, function(msg)
    logW('track fetch failed: ' .. tostring(msg))
    bumpRetryDelay()
    scheduleRetry('track fetch failed')
  end)
end

local function proj(d, a)
  local l = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
  if l < 1e-6 then return 0 end
  return (d.x * a.x + d.y * a.y + d.z * a.z) / l
end

local OUTSIDE_NEAR, OUTSIDE_FAR = 2.5, 12

local function cameraInside(cam)
  if core_camera.isCameraInside then
    local r = core_camera.isCameraInside(0, cam)
    return r == 1 or r == true
  end
  return core_camera.getActiveCamName and core_camera.getActiveCamName(0) == 'driver' or false
end

-- 10 Hz camera-relative position push
local POS_EPS, OUTSIDE_EPS, SPEED_EPS = 0.2, 0.02, 1
local lastX, lastY, lastZ, lastO, lastS = nil, nil, nil, nil, nil


local function pushPos(dt)
  posTimer = posTimer + (dt or 0)
  if posTimer < 0.1 then return end
  posTimer = 0
  if phase ~= 'playing' then return end
  if not (core_camera and core_camera.getPosition and core_camera.getForward and core_camera.getUp) then return end
  local veh = be:getPlayerVehicle(0)
  if not veh then return end
  local cam, fwd, up = core_camera.getPosition(), core_camera.getForward(), core_camera.getUp()
  if not (cam and fwd and up) then return end
  local pos = veh:getPosition()
  local d = { x = pos.x - cam.x, y = pos.y - cam.y, z = pos.z - cam.z }
  local right = {
    x = fwd.y * up.z - fwd.z * up.y,
    y = fwd.z * up.x - fwd.x * up.z,
    z = fwd.x * up.y - fwd.y * up.x,
  }
  local x, y, z = proj(d, right), proj(d, up), -proj(d, fwd)
  local outside = 0
  if cameraInside(cam) then
    x, y, z = 0, 0, 0
  else
    local dist = math.sqrt(x * x + y * y + z * z)
    outside = math.min(1, math.max(0, (dist - OUTSIDE_NEAR) / (OUTSIDE_FAR - OUTSIDE_NEAR)))
  end
  local speed = veh:getVelocity():length()
   if lastX and math.abs(x - lastX) < POS_EPS and math.abs(y - lastY) < POS_EPS
      and math.abs(z - lastZ) < POS_EPS and math.abs(outside - lastO) < OUTSIDE_EPS
      and math.abs(speed - lastS) < SPEED_EPS then
    return
  end
  lastX, lastY, lastZ, lastO, lastS = x, y, z, outside, speed
  js('if(window._jfRadio)window._jfRadio.setPos(%.2f,%.2f,%.2f,%.2f,%.1f);', x, y, z, outside, speed)
end

local function onUpdate(dt)
  if not enabled then return end

  local nowHasVehicle = hasVehicle()
  if nowHasVehicle and not hadVehicle and phase == 'idle' then
    logI('vehicle available, starting playback')
    startFetch()
  elseif not nowHasVehicle and hadVehicle then
    logI('no player vehicle - stopping playback')
    cancelRequest()
    stopPlayback()
    cleanupCurrentCache()
    phase = 'idle'
  end
  hadVehicle = nowHasVehicle

  if request then pumpRequest(dt) end

  if phase == 'waiting_retry' then
    retryTimer = retryTimer + (dt or 0)
    if retryTimer >= retryDelay then
      if nowHasVehicle then startFetch() else phase = 'idle' end
    end
  elseif phase == 'playing' then
    pushPos(dt)
  end
end

-- === CEF Bridge Callbacks ===

local function onTrackEnded()
  logI('track finished: ' .. tostring(currentItemName))
  cleanupCurrentCache()
  if hasVehicle() then startFetch() else phase = 'idle' end
end

local function onTrackError(code)
  logW('playback error (code ' .. tostring(code) .. ') on ' .. tostring(currentItemName))
  cleanupCurrentCache()
  bumpRetryDelay()
  if hasVehicle() then scheduleRetry('playback failed') else phase = 'idle' end
end

-- === Skip Track ===

local function skipTrack()
  if not enabled then return end
  if not hasVehicle() then
    logI('skip pressed with no player vehicle - ignored')
    return
  end
  logI('skip requested')
  cancelRequest()
  stopPlayback()
  cleanupCurrentCache()
  resetRetryDelay()
  startFetch()
end

-- === Extension Lifecycle ===

local function onExtensionLoaded()
  cfg = loadConfig()
  enabled = cfg ~= nil
  if enabled then
    logI(string.format('loaded, target %s:%d, cache %s, keep_cache=%s',
      cfg.host, cfg.port, CACHE_DIR, tostring(cfg.keepCache)))
  end
end

local function onExtensionUnloaded()
  if not enabled then return end
  cancelRequest()
  if nextItem and not cfg.keepCache then pcall(os.remove, nextItem.path) end
  nextItem = nil
  stopPlayback()
  cleanupCurrentCache()
end

local function onSettingsChanged()
  if enabled and phase == 'playing' then
    js('if(window._jfRadio)window._jfRadio.setVolume(%f);', radioVolume())
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.skipTrack = skipTrack
M.onTrackEnded = onTrackEnded
M.onTrackError = onTrackError
M.onSettingsChanged = onSettingsChanged

return M
