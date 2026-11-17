// Dashboard host search: filters rows client-side by partial, case-insensitive
// hostname match. The table is re-rendered every 3s by htmx, so the filter is
// re-applied after each swap.
(function () {
  var input = document.getElementById("host-search");
  if (!input) return;

  function apply() {
    var q = input.value.trim().toLowerCase();
    var rows = document.querySelectorAll("#agents table.agents tbody tr");
    var shown = 0;
    rows.forEach(function (tr) {
      var match = !q || (tr.dataset.host || "").indexOf(q) !== -1;
      tr.hidden = !match;
      if (match) shown++;
    });
    var none = document.getElementById("no-match");
    if (none) none.hidden = !(q && rows.length && shown === 0);
  }

  input.addEventListener("input", apply);
  document.body.addEventListener("htmx:afterSwap", apply);
})();
