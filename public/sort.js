// Dashboard column sorting (Status, Host). Click a header to sort ascending,
// again for descending, a third time to return to the server's severity order.
// The table is re-rendered every 3s by htmx, so the chosen sort is kept here
// and re-applied after each swap.
(function () {
  var sortKey = null; // "status" | "host" | null
  var dir = 1;
  try {
    var saved = JSON.parse(sessionStorage.getItem("janehq.sort") || "null");
    if (saved && (saved.key === "status" || saved.key === "host")) {
      sortKey = saved.key;
      dir = saved.dir === -1 ? -1 : 1;
    }
  } catch (e) {}

  function apply() {
    var table = document.querySelector("#agents table.agents");
    if (!table) return;
    var tbody = table.tBodies[0];
    var rows = Array.prototype.slice.call(tbody.rows);
    rows.forEach(function (tr, i) { if (tr.dataset.idx === undefined) tr.dataset.idx = i; });

    rows.sort(function (a, b) {
      var c = 0;
      if (sortKey === "host") {
        var ha = a.dataset.host || "", hb = b.dataset.host || "";
        c = ha < hb ? -1 : ha > hb ? 1 : 0;
      } else if (sortKey === "status") {
        c = (+a.dataset.status) - (+b.dataset.status);
      }
      return c * dir || (+a.dataset.idx) - (+b.dataset.idx);
    });
    rows.forEach(function (tr) { tbody.appendChild(tr); });

    table.querySelectorAll("th.sortable").forEach(function (th) {
      var active = th.dataset.sort === sortKey;
      th.setAttribute("aria-sort", active ? (dir === 1 ? "ascending" : "descending") : "none");
    });
  }

  function toggle(th) {
    var key = th.dataset.sort;
    if (sortKey !== key) { sortKey = key; dir = 1; }
    else if (dir === 1) { dir = -1; }
    else { sortKey = null; dir = 1; }
    try { sessionStorage.setItem("janehq.sort", JSON.stringify({ key: sortKey, dir: dir })); } catch (e) {}
    // Restore server order first so "no sort" really is the original order.
    document.querySelectorAll("#agents table.agents tbody tr").forEach(function (tr) { delete tr.dataset.idx; });
    apply();
  }

  document.addEventListener("click", function (e) {
    var th = e.target.closest && e.target.closest("th.sortable");
    if (th) toggle(th);
  });
  document.addEventListener("keydown", function (e) {
    if ((e.key === "Enter" || e.key === " ") && e.target.matches && e.target.matches("th.sortable")) {
      e.preventDefault();
      toggle(e.target);
    }
  });
  document.body.addEventListener("htmx:afterSwap", apply);
})();
