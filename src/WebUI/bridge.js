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

  // available=false in a plain browser (design preview); the UI falls back to mock data.
  window.volante = { call: call, available: !!wv };
})();
