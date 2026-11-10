// Group the Host page's checks table by any column. Click a header to group
// by it; click again to ungroup. Plain client-side reordering of existing rows.
(function () {
  var table = document.getElementById("checks-table");
  if (!table) return;
  var body = table.tBodies[0];
  var rows = Array.prototype.slice.call(body.rows);
  var buttons = table.querySelectorAll(".group-th");
  var cols = table.querySelectorAll("thead th");
  var active = null;

  function render() {
    Array.prototype.slice.call(body.querySelectorAll(".group-row")).forEach(function (r) { r.remove(); });
    buttons.forEach(function (b) { b.classList.toggle("active", b.dataset.col === active); });
    if (active === null) {
      rows.forEach(function (r) { body.appendChild(r); });
      return;
    }
    var idx = Array.prototype.findIndex.call(cols, function (c) { return c.dataset.col === active || (c.firstElementChild && c.firstElementChild.dataset.col === active); });
    var groups = {};
    var order = [];
    rows.forEach(function (r) {
      var key = r.cells[idx].textContent.trim() || "(none)";
      if (!groups[key]) { groups[key] = []; order.push(key); }
      groups[key].push(r);
    });
    order.sort(function (a, b) { return a.localeCompare(b, undefined, { numeric: true }); });
    order.forEach(function (key) {
      var h = document.createElement("tr");
      h.className = "group-row";
      var td = document.createElement("td");
      td.colSpan = cols.length;
      td.textContent = active + ": " + key + " (" + groups[key].length + ")";
      h.appendChild(td);
      body.appendChild(h);
      groups[key].forEach(function (r) { body.appendChild(r); });
    });
  }

  buttons.forEach(function (b) {
    b.addEventListener("click", function () {
      active = active === b.dataset.col ? null : b.dataset.col;
      render();
    });
  });
})();
