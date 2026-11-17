// Metrics page: any change to host / date / range reloads with the new query;
// the ‹ › buttons step the date by a day.
(function () {
  var form = document.querySelector(".metrics-form");
  if (!form) return;
  form.addEventListener("change", function () { form.submit(); });
  form.querySelectorAll("[data-days]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var input = form.elements.date;
      var d = new Date((input.value || new Date().toISOString().slice(0, 10)) + "T00:00:00Z");
      d.setUTCDate(d.getUTCDate() + parseInt(btn.dataset.days, 10));
      input.value = d.toISOString().slice(0, 10);
      form.submit();
    });
  });
})();

// Top processes: clicking a process name opens a modal with its details.
(function () {
  var modal = document.getElementById("proc-modal");
  if (!modal) return;
  var title = document.getElementById("proc-title");
  var body = document.getElementById("proc-body");
  function dur(s) {
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    return d ? d + "d " + h + "h " + m + "m" : h ? h + "h " + m + "m" : m ? m + "m " + (s % 60) + "s" : s + "s";
  }
  function row(k, v, cls) {
    if (v === null || v === undefined || v === "") return;
    var dt = document.createElement("dt"), dd = document.createElement("dd");
    dt.textContent = k; dd.textContent = v;
    if (cls) dd.className = cls;
    body.appendChild(dt); body.appendChild(dd);
  }
  function close() { modal.hidden = true; }
  document.addEventListener("click", function (e) {
    var btn = e.target.closest && e.target.closest(".proc-link");
    if (btn) {
      var p = JSON.parse(btn.dataset.proc);
      title.textContent = p.name;
      body.textContent = "";
      row("PID", p.pid);
      row("User", p.user);
      row("Uptime", p.uptime == null ? null : dur(p.uptime));
      row("Memory", p.rss);
      row("CPU", p.cpu + "%");
      row("Disk read", p.read);
      row("Disk write", p.write);
      row("Command line", p.cmdline, "proc-cmd");
      modal.hidden = false;
    } else if (e.target === modal || (e.target.closest && e.target.closest("#proc-modal .glance-close"))) {
      close();
    }
  });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") close(); });
})();
