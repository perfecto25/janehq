// Topbar Admin dropdown. The menu itself is a plain <details> element — this
// only adds the behaviour <details> lacks: closing when you click elsewhere or
// press Esc.
(function () {
  function menus() { return document.querySelectorAll('.topnav details.menu[open]'); }

  document.addEventListener('click', function (e) {
    menus().forEach(function (m) {
      if (!m.contains(e.target)) m.open = false;
    });
  });

  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    menus().forEach(function (m) { m.open = false; });
  });

  // Dashboard group filter: picking a group reloads at /?group=<id>. The
  // <noscript> submit button covers the no-JS case.
  document.addEventListener('change', function (e) {
    if (e.target.id === 'group-select') e.target.form.submit();
  });
})();
