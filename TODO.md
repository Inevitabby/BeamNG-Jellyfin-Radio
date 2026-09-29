# TODO

- TWEAK: `keep_cache`: Rename to `debug_keep_cache` to prevent confusion.
- FEAT: Pre-download one file ahead of time.
- ~~FEAT: EQ, room, and doppler settings.~~
- TWEAK: Set mpris / player title to current track name? (currently it's "BeamNG Main UI")
- PERF: Measure performance.
- PERF: `connect()` is sync. It's not detectable for me because I am (1) running Jellyfin on localhost and (2) Linux networking is instant (so I never trigger the 0.5s worst-case freeze), but I know (a) from experience that Windows lives in a bizarro world where the networking is dumb and (2) this is terrible practice anyways and should be done async.
