// Click-to-glance modal for the dashboard.
//
// The eye button in each row fetches /partials/glance/:hostname via htmx into
// #glance-body; this script owns showing the surrounding modal, dismissing it
// (close button, backdrop click, Esc), and pausing the table's 3s poll while
// it is open.
(function () {
  var open = false;
  var opener = null; // row button that opened the modal, for focus restore

  function modal() { return document.getElementById('glance'); }

  function show() {
    var m = modal();
    if (!m) return;
    open = true;
    m.hidden = false;
    m.classList.add('is-open');
    m.setAttribute('aria-hidden', 'false');
    var close = m.querySelector('.glance-close');
    if (close) close.focus();
  }

  function hide() {
    var m = modal();
    if (!m || !open) return;
    open = false;
    m.hidden = true;
    m.classList.remove('is-open');
    m.setAttribute('aria-hidden', 'true');
    if (opener && document.body.contains(opener)) opener.focus();
    opener = null;
  }

  document.addEventListener('click', function (e) {
    if (!e.target.closest) return;
    // Close button, or the dimmed backdrop outside the card.
    if (e.target.closest('.glance-close') || e.target === modal()) hide();
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') hide();
  });

  document.body.addEventListener('htmx:beforeRequest', function (e) {
    var elt = e.detail.elt;
    // Freeze the agent table while the modal is up: swapping the rows would
    // replace the button we want to hand focus back to.
    if (open && elt && elt.id === 'agents') {
      e.preventDefault();
      return;
    }
    // Open as soon as the fetch starts, so the card never shows the host you
    // glanced at previously.
    if (elt && elt.classList && elt.classList.contains('glance-btn')) {
      opener = elt;
      var body = document.getElementById('glance-body');
      if (body) body.innerHTML = '<p class="muted">Loading…</p>';
      show();
    }
  });

  document.body.addEventListener('htmx:responseError', function (e) {
    var elt = e.detail.elt;
    if (!elt || !elt.classList || !elt.classList.contains('glance-btn')) return;
    var body = document.getElementById('glance-body');
    if (body) body.innerHTML = '<p class="muted">This host is no longer reporting.</p>';
  });
})();
