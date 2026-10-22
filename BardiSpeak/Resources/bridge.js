// Injected into ipc.bardi.co.id at document start.
// - The page never gets the real mic: getUserMedia returns our preset track.
// - Swift calls window.__bardi.devices(), connect(camera), play(id, base64, camera).
(() => {
  const emit = (type, data) => {
    try { webkit.messageHandlers.bardi.postMessage({type, ...data}); } catch (e) {}
  };
  const log = (...a) => emit('log', {text: a.map(String).join(' ')});
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  const B = window.__bardi = {pcs: new Set(), ctx: null, dest: null, current: null};

  // Diagnostics, only with --debug: log failed requests and socket closes
  // (host + path only, no query/tokens). Off by default so we never touch the page's network.
  if (window.__bardiDebug) {
  const short = u => { try { const x = new URL(u, location.href); return x.host + x.pathname; } catch (e) { return String(u).slice(0, 80); } };
  // Tuya APIs answer 200 with {success:false, errorCode, errorMsg} on failure.
  const apiError = (url, text) => {
    if (!text || text[0] !== '{' || !/"success"\s*:\s*false/.test(text)) return;
    try {
      const j = JSON.parse(text);
      log('api error', url, j.errorCode || j.code || '', j.errorMsg || j.msg || '');
      // The login ended (e.g. a newer login elsewhere). The page stays on /playback, so tell Swift.
      if (/SESSION_INVALID|LOGIN_EXPIRED|TOKEN_INVALID/i.test(j.errorCode || j.errorMsg || '')) emit('session', {valid: false});
    }
    catch (e) { log('api error', url, text.slice(0, 120)); }
  };
  const origFetch = window.fetch;
  window.fetch = async function (input, init) {
    const url = short(typeof input === 'string' ? input : input && input.url);
    const t0 = Date.now();
    try {
      const r = await origFetch.apply(this, arguments);
      if (!r.ok) log('fetch', r.status, url);
      else r.clone().text().then(t => apiError(url, t)).catch(() => {});
      return r;
    } catch (e) { log('fetch failed', url, e.message, 'after', Date.now() - t0, 'ms'); throw e; }
  };
  const origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) {
    const url = short(u);
    this.addEventListener('loadend', () => {
      if (this.status === 0 || this.status >= 400) log('xhr', this.status, m, url);
      else if (this.responseType === '' || this.responseType === 'text') apiError(url, this.responseText);
    });
    return origOpen.apply(this, arguments);
  };
  const OrigWS = window.WebSocket;
  window.WebSocket = function (u, p) {
    const ws = p === undefined ? new OrigWS(u) : new OrigWS(u, p);
    const url = short(u);
    log('ws open', url);
    ws.addEventListener('error', () => log('ws error', url));
    ws.addEventListener('close', e => log('ws close', e.code, url));
    return ws;
  };
  window.WebSocket.prototype = OrigWS.prototype;
  Object.assign(window.WebSocket, {CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3});
  window.addEventListener('error', e => log('page error', e.message), true);
  window.addEventListener('unhandledrejection', e => log('page rejection', String(e.reason && e.reason.message || e.reason).slice(0, 150)));
  }

  // The app keeps the portal window hidden, and the player may refuse to start
  // live view on a hidden page. Always report "visible" to the page.
  const realVisibility = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState').get;
  Object.defineProperty(document, 'visibilityState', {get: () => 'visible', configurable: true});
  Object.defineProperty(document, 'hidden', {get: () => false, configurable: true});
  document.addEventListener('visibilitychange', e => e.stopImmediatePropagation(), true);

  const ensureCtx = () => {
    if (!B.ctx) {
      B.ctx = new AudioContext({sampleRate: 48000});
      B.dest = B.ctx.createMediaStreamDestination();
    }
    return B.ctx;
  };
  const presetTrack = () => { ensureCtx(); return B.dest.stream.getAudioTracks()[0]; };

  // Track the page's peer connections, so we can find the audio sender later.
  const P = RTCPeerConnection.prototype;
  const origAddTransceiver = P.addTransceiver;
  P.addTransceiver = function (...a) {
    if (!B.pcs.has(this)) {
      B.pcs.add(this);
      this.__device = B.lastClicked;  // the camera whose name was clicked last
      log('new connection for', this.__device);
      this.addEventListener('track', e => {
        if (e.track.kind === 'audio') { e.track.enabled = false; log('camera audio off'); }
      });
      this.addEventListener('connectionstatechange', () => {
        log('pc', this.connectionState);
        emit('camera', {state: this.connectionState, device: this.__device});
      });
    }
    return origAddTransceiver.apply(this, a);
  };

  // No real mic: the page's own talk button also sends preset audio (or silence).
  // Keep the real mic function for live talk (Hold to Talk) before we replace it.
  const realGetUserMedia = window.MediaDevices && MediaDevices.prototype.getUserMedia;

  // Patch the instance, the prototype and the old callback API, so no path reaches the mic.
  // (Swift also denies every capture request, as a hard guarantee.)
  const fakeMic = async (c) => {
    log('getUserMedia', JSON.stringify(c));
    return new MediaStream([presetTrack().clone()]);
  };
  if (window.MediaDevices) MediaDevices.prototype.getUserMedia = fakeMic;
  if (!navigator.mediaDevices) Object.defineProperty(navigator, 'mediaDevices', {value: {}});
  navigator.mediaDevices.getUserMedia = fakeMic;
  navigator.getUserMedia = navigator.webkitGetUserMedia = (c, ok, fail) => fakeMic(c).then(ok, fail);

  // Never play the camera's own sound on the Mac. Otherwise a preset comes back through
  // the camera's mic and out of the Mac's speakers (echo), and Hold to Talk howls.
  // Two layers: every media element is muted at volume 0, and the camera's incoming
  // audio track is switched off (see addTransceiver below), which covers Web Audio too.
  const silence = m => { if (!m.muted) m.muted = true; if (m.volume !== 0) m.volume = 0; };
  const muteAll = () => document.querySelectorAll('video, audio').forEach(silence);
  document.addEventListener('play', e => { if (e.target instanceof HTMLMediaElement) silence(e.target); }, true);
  document.addEventListener('volumechange', e => { if (e.target instanceof HTMLMediaElement) silence(e.target); }, true);
  setInterval(muteAll, 1000);

  // Tell Swift when the page moves between /login and /playback (client-side routing).
  let lastPath = null;
  setInterval(() => {
    if (location.pathname !== lastPath) {
      lastPath = location.pathname;
      emit('route', {path: lastPath});
    }
  }, 1000);

  const connectedPC = (name) => [...B.pcs].reverse()
    .find(p => p.connectionState === 'connected' && p.__device === name);

  // First element whose own text matches, found by text so we don't depend on class names.
  const findByText = (re) => {
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(); n; n = w.nextNode()) {
      if (re.test(n.textContent.trim())) return n.parentElement;
    }
    return null;
  };
  const escapeRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  // Camera names from the portal's "All Devices (N)" tree, found by text, not class names.
  // React may split "All Devices (2)" into several text nodes, so skip the whole
  // header element and any piece that is only brackets or digits.
  const isNoise = t => /^All Devices/.test(t) || /^[()\d\s]+$/.test(t);
  const namesNear = (all, n) => {
    // Climb from the header, but never into the player area (it holds <video>/<canvas>).
    for (let a = all.parentElement; a && a !== document.body && !a.querySelector('video, canvas'); a = a.parentElement) {
      const names = [];
      const w = document.createTreeWalker(a, NodeFilter.SHOW_TEXT);
      for (let t = w.nextNode(); t; t = w.nextNode()) {
        const s = t.textContent.trim();
        const after = all.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING;  // names come after the header
        if (s && after && !all.contains(t) && !isNoise(s)) names.push(s);
      }
      if (names.length >= n) return names.slice(0, n);
    }
    return [];
  };
  B.devices = async () => {
    let expanded = false;
    for (let i = 0; i < 30; i++) {
      if (location.pathname.startsWith('/login')) return [];
      const all = findByText(/^All Devices/);
      if (all) {
        let header = all;  // the count may sit in a parent element: "All Devices" "(" "2" ")"
        while (header.parentElement && !/All Devices\s*\(\s*\d+\s*\)/.test(header.textContent)) header = header.parentElement;
        const m = header.textContent.match(/All Devices\s*\(\s*(\d+)\s*\)/);
        const n = m ? Number(m[1]) : 0;
        const names = n ? namesNear(all, n) : [];
        if (names.length) { B.knownDevices = names; log('cameras:', names.join(' | ')); return names; }
        if (n && !expanded) { all.click(); expanded = true; }
      }
      await sleep(300);
    }
    log('no camera list; page text:', (document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 200));
    return [];
  };

  // Clicks on a camera name in the portal (yours or ours) tell us which camera
  // the next peer connection belongs to.
  document.addEventListener('click', e => {
    const t = (e.target.textContent || '').trim();
    if (B.knownDevices && B.knownDevices.includes(t)) B.lastClicked = t;
  }, true);

  // Open live view for the camera named `name` and wait until WebRTC is connected.
  B.connect = async (name, timeoutMs = 25000) => {
    const deviceRe = new RegExp('^' + escapeRe(name) + '$');
    const t0 = Date.now();
    let clicked = false, expanded = false, clicks = 0, clickedAt = 0;
    const starting = () => [...B.pcs].some(p => p.__device === name && /new|connecting/.test(p.connectionState));
    while (Date.now() - t0 < timeoutMs) {
      if (connectedPC(name)) return true;
      if (location.pathname.startsWith('/login')) throw new Error('Sign in needed. Open the camera portal and scan the QR code.');
      // The portal sometimes ignores a click (seen when the camera's old stream had closed).
      // If nothing starts within 6 s, click once more.
      if (clicked && clicks < 2 && !starting() && Date.now() - clickedAt > 6000) {
        log('no connection started; clicking again');
        clicked = false;
      }
      if (!clicked) {
        const device = findByText(deviceRe);
        if (device) {
          B.lastClicked = name;
          device.click();
          clicked = true;
          clicks++;
          clickedAt = Date.now();
          emit('camera', {state: 'connecting', device: name});
          log('clicked device', name, '| real visibility:', realVisibility.call(document), '| pcs:', B.pcs.size);
        } else if (!expanded) {
          const all = findByText(/^All Devices/);
          if (all) { all.click(); expanded = true; log('expanded device list'); }
        }
      }
      await sleep(400);
    }
    log('connect timeout | clicked:', clicked, '| pcs:', B.pcs.size, [...B.pcs].map(p => p.connectionState).join(','));
    throw new Error(clicked ? 'The camera did not connect in time.' : 'Camera "' + name + '" was not found in the portal.');
  };

  const audioSender = (name) => {
    const pc = connectedPC(name);
    if (!pc) throw new Error('Camera not connected.');
    return pc.getTransceivers().find(t => t.receiver.track.kind === 'audio').sender;
  };

  const decode = async (b64) => {
    const bytes = Uint8Array.from(atob(b64), ch => ch.charCodeAt(0));
    return ensureCtx().decodeAudioData(bytes.buffer);
  };

  B.stop = async () => {
    const cur = B.current;
    B.current = null;
    if (cur) { try { cur.src.stop(); } catch (e) {} await cur.sender.replaceTrack(null); }
    emit('playing', {id: null});
  };

  // Decode the file and play it. Talk is on only while it plays.
  B.play = async (id, b64, name) => {
    if (B.talkTrack) await B.talkStop();
    const buf = await decode(b64);
    await ensureCtx().resume();
    const sender = audioSender(name);
    await B.stop();
    await sender.replaceTrack(presetTrack());
    const src = B.ctx.createBufferSource();
    src.buffer = buf;
    src.connect(B.dest);
    const me = {src, sender, id};
    src.onended = async () => {
      if (B.current !== me) return;
      B.current = null;
      await sender.replaceTrack(null);
      emit('playing', {id: null});
      log('ended', id);
    };
    B.current = me;
    src.start();
    emit('playing', {id, duration: buf.duration});
    log('play', id, buf.duration.toFixed(1) + 's');
    return buf.duration;
  };

  // Live talk: the real mic goes to the camera only while the user holds Talk.
  // Swift grants the mic permission only during this call.
  B.talkStart = async (name) => {
    B.wantTalk = true;
    await B.connect(name);
    if (!B.wantTalk) return false;
    if (!realGetUserMedia || !navigator.mediaDevices) throw new Error('Live talk is not supported in this web view.');
    await B.stop();
    let track;
    try {
      const stream = await realGetUserMedia.call(navigator.mediaDevices, {audio: {echoCancellation: true, noiseSuppression: true}});
      track = stream.getAudioTracks()[0];
    } catch (e) {
      if (!B.wantTalk) return false;  // released before the mic opened
      throw new Error('Could not open the microphone: ' + e.message);
    }
    if (!B.wantTalk) { track.stop(); return false; }
    B.talkTrack = track;
    const sender = audioSender(name);
    await sender.replaceTrack(track);
    B.talkSender = sender;
    emit('talking', {on: true});
    log('talk start');
    return true;
  };

  B.talkStop = async () => {
    B.wantTalk = false;
    const track = B.talkTrack;
    B.talkTrack = null;
    if (!track) return;
    try { await B.talkSender.replaceTrack(null); } catch (e) {}
    B.talkSender = null;
    track.stop();  // turns the Mac's mic off (the orange dot goes away)
    emit('talking', {on: false});
    log('talk stop');
  };

  log('bridge loaded');
})();
