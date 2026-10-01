# TODO

## FEAT

- [X] FEAT: Pre-download one file ahead of time.
  - (Currently does *not* pre-load while on foot, only when already in vehicle)
    * Intertwined: Music Model Changes?
- [X] FEAT: EQ, room, and doppler settings. *(Ended up opting for a simpler audio graph, still fairly immersive)*
  - [X] FEAT: Improve in-car audio (directional in-car? how the hell does real car audio work)
- [ ] FEAT: Hidden poweruser config option to customize the Jellyfin query

## TWEAK

- [ ] TWEAK: `keep_cache`: Rename to `debug_keep_cache` to prevent confusion.
- [ ] TWEAK: Set mpris / player title to current track name? (currently it's "BeamNG Main UI")
  - Intertwined: NPC Music?

## PERF

- [ ] PERF: Measure performance automatically.
- [X] PERF: Make `connect()` non-blocking.

## SLIPPERY SCOPE

- [ ] SLIPPERY SCOPE: In-game configuration menu?
- [ ] SLIPPERY SCOPE: Music Model Changes? (features that could ruin state machine simplicity + complicate implementing the other + make the mod a lot less robust) 
  - [ ] SLIPPERY SCOPE: Music Start/Stop?
  - [ ] SLIPPERY SCOPE: NPC Music?
