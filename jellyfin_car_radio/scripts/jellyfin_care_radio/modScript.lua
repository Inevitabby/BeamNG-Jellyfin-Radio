if setExtensionUnloadMode then
  pcall(setExtensionUnloadMode, 'jellyfin_radio', 'manual')
end

local ok, err = pcall(function()
  extensions.load('jellyfin_radio')
end)
if not ok then
  log('E', 'JellyfinRadio', '[JellyfinRadio] failed to load extension: ' .. tostring(err))
  return
end

log('I', 'JellyfinRadio', '[JellyfinRadio] mod script executed')
