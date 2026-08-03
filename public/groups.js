// Dual-column host picker for the New/Edit Group form.
//
// Two <ul class="host-list"> columns; hosts move between them by drag-and-drop
// or by click (drag is fiddly on trackpads and impossible on touch). On submit
// the "Hosts in Group" column is serialized into the hidden `hostnames` field
// as a JSON array — that is what src/web/groups.cr persists.
(function () {
  var form = document.getElementById('group-form');
  if (!form) return;

  var inGroup = document.getElementById('in-group');
  var available = document.getElementById('available');
  var field = document.getElementById('group-hostnames');
  var dragged = null;

  function other(list) { return list === inGroup ? available : inGroup; }

  function sortList(list) {
    var items = Array.prototype.slice.call(list.children);
    items.sort(function (a, b) {
      return a.dataset.hostname.localeCompare(b.dataset.hostname);
    });
    items.forEach(function (li) { list.appendChild(li); });
  }

  function refresh() {
    [inGroup, available].forEach(function (list) {
      var n = list.children.length;
      var label = document.querySelector('[data-count-for="' + list.id + '"]');
      if (label) label.textContent = '(' + n + ')';
      list.classList.toggle('is-empty', n === 0);
    });
  }

  function move(item, list) {
    list.appendChild(item);
    sortList(list);
    refresh();
  }

  // Click to move — the keyboard/touch path, and quicker than dragging.
  document.addEventListener('click', function (e) {
    var item = e.target.closest && e.target.closest('.host-item');
    if (!item || !form.contains(item)) return;
    move(item, other(item.parentElement));
  });

  document.addEventListener('dragstart', function (e) {
    var item = e.target.closest && e.target.closest('.host-item');
    if (!item || !form.contains(item)) return;
    dragged = item;
    item.classList.add('is-dragging');
    e.dataTransfer.effectAllowed = 'move';
    // Firefox refuses to start a drag without data on the transfer.
    e.dataTransfer.setData('text/plain', item.dataset.hostname);
  });

  document.addEventListener('dragend', function () {
    if (dragged) dragged.classList.remove('is-dragging');
    dragged = null;
    document.querySelectorAll('.host-list.is-over').forEach(function (l) {
      l.classList.remove('is-over');
    });
  });

  [inGroup, available].forEach(function (list) {
    list.addEventListener('dragover', function (e) {
      if (!dragged) return;
      e.preventDefault(); // marks this list as a valid drop target
      e.dataTransfer.dropEffect = 'move';
      list.classList.add('is-over');
    });

    list.addEventListener('dragleave', function (e) {
      if (e.relatedTarget && list.contains(e.relatedTarget)) return;
      list.classList.remove('is-over');
    });

    list.addEventListener('drop', function (e) {
      e.preventDefault();
      list.classList.remove('is-over');
      if (dragged) move(dragged, list);
    });
  });

  form.addEventListener('submit', function () {
    var names = Array.prototype.map.call(inGroup.children, function (li) {
      return li.dataset.hostname;
    });
    field.value = JSON.stringify(names);
  });

  refresh();
})();
