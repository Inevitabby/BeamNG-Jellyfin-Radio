<div align="center">
  <h1>BeamNG.drive Jellyfin Car Radio</h1>
  <p>Yet another car radio / music mod for BeamNG.drive</p>
</div>

<!-- TODO : Demo Video -->

Plays random tracks from a Jellyfin (v12) media server through your car in BeamNG.drive with 3D positional audio, plus:

- Distance muffling
- Cabin bass shelf
- Speed lift
- Loudness normalization

# Install

> [!NOTE]
> For brevity, `${BEAM}` is just shorthand for `~/.local/share/BeamNG/BeamNG.drive/current/` (Linux) or `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\` (Windows).

## 1. Mod

Copy `jellyfin_car_radio` into `${BEAM}/mods/unpacked/`.

<!-- TODO Come up with a CI to "build"? -->

## 2. Configuration

If it doesn't exist, create `${BEAM}/settings/jellyfin_car_radio/config.json`:

```json
{
  "server_url": "http://127.0.0.1:8096",
  "api_key": "your-jellyfin-api-key",
  "volume": 0.42
}
```

> [!NOTE]
> You can create an API key in Jellyfin by navigating `Dashboard` -> `API Keys`.

> [!TIP]
> Once in Beam.ng, you can bind a button to skip the current track (`Options` -> `Controls` -> `Jellyfin Car Radio: Skip Track` (search)). (It is unbound by default.)

# How it Works

Behavior:
- Radio starts automatically once you're in a vehicle.
- Asks Jellyfin for one random audio track (`SortBy=Random&Limit=1`) and downloads it.
  * On track end, does it again.
- Leaving the vehicle stops playback.

Audio Graph:
- Playback happens in Beam.ng's embedded browser (CEF).
  - [`radio.lua`](jellyfin_car_radio/lua/ge/extensions/jellyfin/radio.lua) hands the audio file to [`bridge.js`](jellyfin_car_radio/ui/jellyfin_radio/bridge.js), which plays it through a Web Audio graph.
  - [`radio.lua`](jellyfin_car_radio/lua/ge/extensions/jellyfin/radio.lua) also sends [`bridge.js`](jellyfin_car_radio/ui/jellyfin_radio/bridge.js) the camera-relative car position and vehicle speed at 10 Hz (values are eased).

> [!NOTE]
> The full signal chain and its tunable values (filter cutoffs, gains, distances) live in [`bridge.js`](jellyfin_car_radio/ui/jellyfin_radio/bridge.js). Go play with it!

# Limitations

- No HTTPS support.
- Beam.ng sandbox only allows loopback access by default. So if your Jellyfin isn't on localhost, there is a CLI flag for Beam.ng to disable the sandbox.
- There is no cache deduplication or size cap if you enable `keep_cache`. Don't turn it on unless you are debugging.
- No custom base path / reverse-proxy subpath support in `server_url`, because I don't care.
- Chunked HTTP responses aren't parsed, because I don't care.

# Credits

The poll-for-vehicle loop and CEF/Web Audio bridge are based on [Roadwave](https://www.beamng.com/resources/roadwave-%E2%80%94-in-car-music-player-with-3d-audio.39115/)'s `stream.lua` / `audio.lua`.

