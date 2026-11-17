// Host page: refresh as soon as the agent reports. Long-polls /agent/:host/wait
// (returns when last_seen changes, or after ~15s), then swaps in the fresh
// content from /partials/agent/:host and re-applies the checks grouping.
(function () {
  var live = document.getElementById("agent-live");
  if (!live) return;
  var host = live.dataset.host;
  var seen = live.dataset.seen;
  var stopped = false;
  window.addEventListener("pagehide", function () { stopped = true; });

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  async function loop() {
    while (!stopped) {
      try {
        var w = await fetch("/agent/" + encodeURIComponent(host) + "/wait?since=" + seen, { credentials: "same-origin" });
        if (!w.ok) throw new Error(w.status);
        var j = await w.json();
        var p = await fetch("/partials/agent/" + encodeURIComponent(host), { credentials: "same-origin" });
        if (!p.ok) throw new Error(p.status);
        var html = await p.text();
        var cur = document.getElementById("agent-live");
        var tmp = document.createElement("div");
        tmp.innerHTML = html;
        var next = tmp.firstElementChild;
        if (!cur || !next) return;
        cur.replaceWith(next);
        seen = String(j.last_seen);
        if (window.JaneChecksInit) window.JaneChecksInit();
      } catch (e) {
        await sleep(5000); // login expired, server restarting, ...: back off and retry
      }
    }
  }
  loop();
})();
