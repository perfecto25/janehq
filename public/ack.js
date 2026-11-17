// Ack duration menu. One shared #ack-menu is positioned (fixed) beside the Ack
// button that was clicked; choosing a duration POSTs it and swaps the table.
// The table's 3s poll is frozen while the menu is open so the button the menu
// belongs to is not replaced underneath it.
(function () {
  var menu = document.getElementById('ack-menu');
  if (!menu) return;
  var current = null; // the Ack button the menu is open for

  function close() {
    menu.hidden = true;
    current = null;
  }

  function open(btn) {
    current = btn;
    menu.hidden = false;
    var r = btn.getBoundingClientRect();
    var h = menu.offsetHeight, w = menu.offsetWidth;
    var top = r.bottom + 4;
    if (top + h > window.innerHeight) top = Math.max(4, r.top - h - 4);
    var left = Math.min(r.left, window.innerWidth - w - 8);
    menu.style.top = top + 'px';
    menu.style.left = Math.max(4, left) + 'px';
    var first = menu.querySelector('button');
    if (first) first.focus();
  }

  document.addEventListener('click', function (e) {
    var btn = e.target.closest && e.target.closest('.ack-open');
    if (btn) {
      var same = current === btn;
      close();
      if (!same) open(btn);
      return;
    }
    var item = e.target.closest && e.target.closest('#ack-menu button');
    if (item && current) {
      var b = current;
      close();
      htmx.ajax('POST', b.dataset.url, {
        target: '#agents',
        swap: 'innerHTML',
        values: { minutes: item.dataset.minutes, group: b.dataset.group }
      });
      return;
    }
    close();
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && current) {
      var b = current;
      close();
      b.focus();
    }
  });
  window.addEventListener('scroll', close, true);
  window.addEventListener('resize', close);

  document.body.addEventListener('htmx:beforeRequest', function (e) {
    var elt = e.detail.elt;
    if (current && elt && elt.id === 'agents') e.preventDefault();
  });
})();

// Ack tooltip: place the (position: fixed) bubble just below the "Acked" label.
(function () {
  function place(e) {
    var el = e.target.closest && e.target.closest(".ack-who");
    if (!el) return;
    var r = el.getBoundingClientRect();
    el.style.setProperty("--tip-x", Math.max(8, Math.min(r.left, window.innerWidth - 300)) + "px");
    el.style.setProperty("--tip-y", (r.bottom + 8) + "px");
  }
  document.addEventListener("mouseover", place);
  document.addEventListener("focusin", place);
})();
