// Audio graph:
//
// <audio> element:
//   -> srcNode    
//   -> crossfeed  cabin-only: speaker-style crosstalk
//   -> liftGain   cabin-only: lift volume as vehicle speed increases
//   -> shelf      cabin-only: cabin bass shelf (cabin pressure)
//   -> muffle     lowpasses for inside and outside
//   -> panner     3D position and distance falloff
//   -> speakers
(function () {
  if (window._jfRadio) { return; }

  var el = new Audio();
  el.preload = 'auto';

  // Web Audio objects
  var ctx = null, srcNode = null, normGain = null, liftGain = null;
  var shelf = null, muffle = null, panner = null, xf = null;

  // Latest values from Lua (see setPos)
  var pos = { x: 0, y: 0, z: 0 }; // car position relative to the camera
  var outside = 0; // 0 = in cabin, 1 = well outside
  var speed = 0; // m/s

  // Smoothing time constants (in seconds)
  var POS_TC = 0.08, TONE_TC = 0.15;

  // Lowpass for inside and outside cabin
  var MUFFLE_OPEN = 18000, MUFFLE_CLOSED = 800;

  // Cabin Bass Shelf
  var CABIN_BASS_DB = 2;

  // Cabin crossfeed
  var XF_DIRECT_IN = 0.7, XF_CROSS_IN = 0.3, XF_DIRECT_OUT = 1.0;

  // Cabin-only volume lift. Reaches LIFT_MAX_DB at LIFT_FULL_SPEED (scales with speed squared)
  var LIFT_MAX_DB = 2, LIFT_FULL_SPEED = 35;

  var blobUrl = null;
  var blocked = false; 

  function ease(param, v, tc) {
    if (tc) { param.setTargetAtTime(v, ctx.currentTime, tc); } else { param.value = v; }
  }

  function applyPos(tc) {
    if (!panner) { return; }
    if (panner.positionX) {
      ease(panner.positionX, pos.x, tc);
      ease(panner.positionY, pos.y, tc);
      ease(panner.positionZ, pos.z, tc);
    } else {
      panner.setPosition(pos.x, pos.y, pos.z);
    }
  }

  // Apply muffle, bass shelf, speed lift, and crossfeed
  function applyTone(tc) {
    if (!panner) { return; }
    var cabin = 1 - outside; // 1 in cabin, 0 for outside
    var s = Math.min(1, speed / LIFT_FULL_SPEED); // fraction of full speed
    // 1. Cutoff glides from MUFFLE_OPEN to MUFFLE_CLOSED
    ease(muffle.frequency, MUFFLE_OPEN * Math.pow(MUFFLE_CLOSED / MUFFLE_OPEN, outside), tc);
    // 2. Cabin bass shelf and speed lift fade-out as camera leaves cabin
    ease(shelf.gain, CABIN_BASS_DB * cabin, tc);
    // 3. s * s keeps the lift negligible at low speed. (The 10^(dB/20) converts dB to gain.)
    ease(liftGain.gain, Math.pow(10, LIFT_MAX_DB * s * s * cabin / 20), tc);
    // 4. Crossfeed fade out with the cabin
    for (var i = 0; i < 2; i++) {
      ease(xf.direct[i].gain, XF_DIRECT_OUT + (XF_DIRECT_IN - XF_DIRECT_OUT) * cabin, tc);
      ease(xf.cross[i].gain, XF_CROSS_IN * cabin, tc);
    }
  }

  // Speaker-style crosstalk
  function makeCrossfeed(ctx) {
    var inp = ctx.createGain();
    inp.channelCount = 2; inp.channelCountMode = 'explicit';
    var split = ctx.createChannelSplitter(2), merge = ctx.createChannelMerger(2);
    var direct = [], cross = [];
    inp.connect(split);
    for (var ch = 0; ch < 2; ch++) {
      var d = ctx.createGain(); d.gain.value = XF_DIRECT_IN;
      var lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 700;
      var dl = ctx.createDelay(0.01); dl.delayTime.value = 0.0003;
      var c = ctx.createGain(); c.gain.value = XF_CROSS_IN;
      split.connect(d, ch); d.connect(merge, 0, ch);
      split.connect(lp, ch); lp.connect(dl); dl.connect(c); c.connect(merge, 0, 1 - ch);
      direct.push(d); cross.push(c);
    }
    return { input: inp, output: merge, direct: direct, cross: cross };
  }

  // Creates the audio graph (returns true if graph is ready)
  function build() {
    if (panner) { return true; }
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) { return false; }
    try {
      // 1. Initialize all nodes / objects
      ctx = new AC();
      srcNode = ctx.createMediaElementSource(el);
      xf = makeCrossfeed(ctx);
      normGain = ctx.createGain();
      liftGain = ctx.createGain();
      shelf = ctx.createBiquadFilter();
      shelf.type = 'lowshelf';
      shelf.frequency.value = 65;
      muffle = ctx.createBiquadFilter();
      muffle.type = 'lowpass';
      panner = ctx.createPanner();
      panner.panningModel = 'equalpower';
      panner.distanceModel = 'inverse';
      panner.refDistance = 2.75;
      panner.maxDistance = 400;
      panner.rolloffFactor = 1;

      // 2. Connect everything together
      srcNode.connect(xf.input);
      xf.output.connect(normGain);
      normGain.connect(liftGain);
      liftGain.connect(shelf);
      shelf.connect(muffle);
      muffle.connect(panner);
      panner.connect(ctx.destination);

      // 3. Apply values that arrived before the graph existed (no smoothing).
      applyPos(0);
      applyTone(0);
      return true;
    } catch (e) {
      console.error('jellyfin radio: audio graph failed', e);
      return false;
    }
  }

  // Track finished
  el.addEventListener('ended', function () {
    bngApi.engineLua("extensions.jellyfin_radio.onTrackEnded()");
  });

  // Playback error
  el.addEventListener('error', function () {
    if (!el.getAttribute('src')) { return; }
    bngApi.engineLua("extensions.jellyfin_radio.onTrackError(" +
      (el.error ? el.error.code : 0) + ")");
  });

  // Start or resume playback
  function start() {
    if (!el.getAttribute('src')) { return; }
    if (ctx && ctx.state === 'suspended') { ctx.resume(); }
    var p = el.play();
    if (p && p.catch) {
      p.catch(function (e) {
        var n = (e && e.name) || '';
        if (n === 'AbortError') { return; }
        if (n === 'NotAllowedError') {
          blocked = true;
          var unlock = function () {
            document.removeEventListener('mouseup', unlock, true);
            document.removeEventListener('keyup', unlock, true);
            if (blocked) { blocked = false; start(); }
          };
          document.addEventListener('mouseup', unlock, true);
          document.addEventListener('keyup', unlock, true);
          return;
        }
        bngApi.engineLua("extensions.jellyfin_radio.onTrackError(-1)");
      });
    }
  }

  // API called from radio.lua through be:queueJS.
  window._jfRadio = {
    play: function (path, vol, gainDb) {
      var xhr = new XMLHttpRequest();
      xhr.responseType = 'arraybuffer';
      xhr.onload = function () {
        var buf = xhr.response;
        if (!buf || !buf.byteLength) {
          bngApi.engineLua("extensions.jellyfin_radio.onTrackError(-1)");
          return;
        }
        if (blobUrl) { URL.revokeObjectURL(blobUrl); }
        blobUrl = URL.createObjectURL(new Blob([buf]));
        el.src = blobUrl;
        el.volume = vol * vol;
        build();
        if (normGain) {
          normGain.gain.value = Math.pow(10, Math.max(-20, Math.min(6, +gainDb || 0)) / 20);
        }
        start();
      };
      xhr.onerror = function () {
        bngApi.engineLua("extensions.jellyfin_radio.onTrackError(-1)");
      };
      xhr.open('GET', path, true);
      xhr.send();
    },
    stop: function () {
      blocked = false;
      el.pause();
      el.removeAttribute('src');
      el.load();
      if (blobUrl) { URL.revokeObjectURL(blobUrl); blobUrl = null; }
    },
    setVolume: function (v) { el.volume = v; },
    setPos: function (x, y, z, o, v) {
      pos.x = x; pos.y = y; pos.z = z;
      outside = +o || 0;
      speed = +v || 0;
      applyPos(POS_TC);
      applyTone(TONE_TC);
    }
  };
})();
