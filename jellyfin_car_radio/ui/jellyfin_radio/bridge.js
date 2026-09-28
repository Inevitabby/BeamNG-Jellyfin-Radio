(function () {
  if (window._jfRadio) { return; }
  var el = new Audio();
  el.preload = 'auto';
  var ctx = null, srcNode = null, normGain = null, comp = null, muffle = null, panner = null;
  var pos = { x: 0, y: 0, z: 0 }
  var outside = 0;  // 0 = in cabin, 1 = well outside
  var POS_TC = 0.08, TONE_TC = 0.15;
  var MUFFLE_OPEN = 18000, MUFFLE_CLOSED = 800; // lowpass in cabin and out
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

  function applyTone(tc) {
    if (!panner) { return; }
    ease(muffle.frequency, MUFFLE_OPEN * Math.pow(MUFFLE_CLOSED / MUFFLE_OPEN, outside), tc);
  }

  function build() {
    if (panner) { return true; }
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) { return false; }
    try {
      ctx = new AC();
      srcNode = ctx.createMediaElementSource(el);
      muffle = ctx.createBiquadFilter();
      muffle.type = 'lowpass';
      panner = ctx.createPanner();
      panner.panningModel = 'equalpower';
      panner.distanceModel = 'inverse';
      panner.refDistance = 2;
      panner.maxDistance = 400;
      panner.rolloffFactor = 1;
      srcNode.connect(panner);
      muffle.connect(panner);
      panner.connect(ctx.destination);
      applyPos(0);
      applyTone(0);
      return true;
    } catch (e) {
      console.error('jellyfin radio: audio graph failed', e);
      return false;
    }
  }

  el.addEventListener('ended', function () {
    bngApi.engineLua("extensions.jellyfin_radio.onTrackEnded()");
  });
  el.addEventListener('error', function () {
    if (!el.getAttribute('src')) { return; }
    bngApi.engineLua("extensions.jellyfin_radio.onTrackError(" +
      (el.error ? el.error.code : 0) + ")");
  });

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

  window._jfRadio = {
    play: function (path, vol) {
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
        el.volume = vol;
        build();
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
    setPos: function (x, y, z, o) {
      pos.x = x; pos.y = y; pos.z = z;
      outside = +o || 0;
      applyPos(POS_TC);
      applyTone(TONE_TC);
    }
  };
})();
