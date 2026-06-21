// Volante UI <-> native host bridge.
// The C# WebView2 host receives postMessage({id, command, args}) and replies with
// PostWebMessageAsJson({id, ok, data|error}). volante.call() correlates by id.
(function () {
  var pending = {};
  var seq = 0;
  var wv = window.chrome && window.chrome.webview;

  function call(command, args) {
    if (!wv) return Promise.reject(new Error('Volante host bridge unavailable'));
    var id = 'r' + (++seq);
    return new Promise(function (resolve, reject) {
      pending[id] = { resolve: resolve, reject: reject };
      wv.postMessage(JSON.stringify({ id: id, command: command, args: args || {} }));
    });
  }

  if (wv) {
    wv.addEventListener('message', function (e) {
      var msg = e.data;
      if (typeof msg === 'string') { try { msg = JSON.parse(msg); } catch (_) { return; } }
      if (!msg || !msg.id) return;
      var p = pending[msg.id];
      if (!p) return;
      delete pending[msg.id];
      if (msg.ok) p.resolve(msg.data);
      else p.reject(new Error(msg.error || 'Volante host error'));
    });
  }

  // Window-chrome channel (frameless host): fire-and-forget, no response.
  function win(action, extra) {
    if (!wv) return;
    var msg = { __win: action };
    if (extra) { for (var k in extra) msg[k] = extra[k]; }
    wv.postMessage(JSON.stringify(msg));
  }

  // available=false in a plain browser (design preview); the UI falls back to mock data.
  window.volante = { call: call, win: win, available: !!wv };

  // Frameless window: drag from the top header (excluding the right-side controls)
  // and resize from the edges, handed to the native host via WM_NCLBUTTONDOWN.
  if (wv) {
    document.addEventListener('pointerdown', function (e) {
      if (e.button !== 0) return;
      var w = window.innerWidth, h = window.innerHeight, x = e.clientX, y = e.clientY, g = 6, ht = 0;
      var L = x <= g, R = x >= w - g, T = y <= g, B = y >= h - g;
      if (T && L) ht = 13; else if (T && R) ht = 14; else if (B && L) ht = 16; else if (B && R) ht = 17;
      else if (L) ht = 10; else if (R) ht = 11; else if (T) ht = 12; else if (B) ht = 15;
      else if (y <= 36 && x < w - 330) ht = 2; // caption drag; right 330px holds the controls
      if (ht) { e.preventDefault(); win('ht', { ht: ht }); }
    }, true);
  }
})();
