<div align="center">
  <h1>BeamNG.drive Jellyfin Car Radio</h1>
  <p>Immersive car radio that plays music from your Jellyfin media server.</p>
  <p>
    <img alt="BeamNG.drive 0.39" src="https://img.shields.io/badge/BeamNG.drive-0.39-orange">
    <img alt="Jellyfin 12.1" src="https://img.shields.io/badge/Jellyfin-12.1-00a4dc?logo=jellyfin&logoColor=white">
    <a href="../../releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/inevitabby/BeamNG-Jellyfin-Radio"></a>
  </p>
</div>

<div align="center">
  <a href="https://cloud.disroot.org/s/sDzxbQfHxnJYrZ3?dir=/&editing=false&openfile=true">
    <img src="images/thumbnail.png" width="630" alt="Watch Demo"/>
  </a>
</div>

# Installation

> [!NOTE]
> For brevity, `${BEAM}` is shorthand for `~/.local/share/BeamNG/BeamNG.drive/current/` (Linux), or `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\` (Windows).

1. Download `jellyfin_car_radio.zip` from the latest [Release](../../releases) and put it in your mods folder (`${BEAM}/mods/`).
2. Create / edit `${BEAM}/settings/jellyfin_car_radio/config.json`:

```json
{
  "server_url": "http://127.0.0.1:8096",
  "api_key": "your-jellyfin-api-key"
}
```

3. Generate and fill-in your Jellyfin API key (in Jellyfin go to `Dashboard` -> `API Keys`)

# Keybinds

- `Jellyfin Car Radio: Skip Track` (Unbound)

> [!IMPORTANT]
> Radio volume follows BeamNG's own Master and Music sliders.

# How it Works

Radio starts & stops automatically when you enter & leave a vehicle, respectively. In a little more detail:

1. [`radio.lua`](jellyfin_car_radio/lua/ge/extensions/jellyfin/radio.lua) downloads tracks from Jellyfin (`SortBy=Random&Limit=1`) and sends it to [`bridge.js`](jellyfin_car_radio/ui/jellyfin_radio/bridge.js).
2. Playback happens in BeamNG's embedded browser (CEF), where [`bridge.js`](jellyfin_car_radio/ui/jellyfin_radio/bridge.js) plays the file through a Web Audio graph to apply:
    - 3D position,
    - Cabin bass shelf and crossfeed,
    - Distance muffling,
    - Loudness normalization (if LUFS scan is enabled in Jellyfin), and
    - Speed lift
3. While a track plays, [`radio.lua`](jellyfin_car_radio/lua/ge/extensions/jellyfin/radio.lua) sends [`bridge.js`](jellyfin_car_radio/ui/jellyfin_radio/bridge.js) the camera-relative car position and vehicle speed at 10 Hz (values are eased to smooth changes).

# Limitations

- No HTTPS support.
- BeamNG.drive's sandbox only allows loopback access by default. So if your Jellyfin isn't on localhost, you'll need to disable the sandbox. I haven't tested how this myself, because I don't care.
- No custom base path / reverse-proxy subpath support in `server_url`, because I don't care.
- Chunked HTTP responses aren't parsed, because I don't care.

# Credits

The poll-for-vehicle loop and CEF/Web Audio bridge are based on [Roadwave](https://www.beamng.com/resources/roadwave-%E2%80%94-in-car-music-player-with-3d-audio.39115/)'s `stream.lua` / `audio.lua`.
