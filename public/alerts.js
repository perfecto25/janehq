// Multi-select pickers on the New/Edit Alert Group form.
//
// Each picker is a <details> holding a plain checkbox group, so the form still
// submits correctly with JS disabled (the server reads the repeated params and
// renders the collapsed labels itself). This adds what <details> lacks: a live
// summary label, filtering, clearing, and closing on outside click / Esc — plus
// swapping the destination field to match the selected alert type.
(function () {
  var form = document.getElementById('alert-form');
  if (!form) return;

  var pickers = Array.prototype.slice.call(form.querySelectorAll('.picker'));

  function boxes(picker) {
    return Array.prototype.slice.call(picker.querySelectorAll('input[type=checkbox]'));
  }

  function refresh(picker) {
    var labels = boxes(picker).filter(function (cb) { return cb.checked; })
      .map(function (cb) { return cb.dataset.label || cb.value; });
    var out = picker.querySelector('.picker-label');
    out.textContent = labels.length ? labels.join(', ') : picker.dataset.any;
    out.classList.toggle('is-any', labels.length === 0);
  }

  pickers.forEach(function (picker) {
    refresh(picker);

    picker.addEventListener('change', function () { refresh(picker); });

    var clear = picker.querySelector('.picker-clear');
    if (clear) {
      clear.addEventListener('click', function () {
        boxes(picker).forEach(function (cb) { cb.checked = false; });
        refresh(picker);
      });
    }

    var filter = picker.querySelector('.picker-filter');
    if (filter) {
      filter.addEventListener('input', function () {
        var needle = filter.value.trim().toLowerCase();
        picker.querySelectorAll('.picker-item').forEach(function (item) {
          var hit = item.textContent.toLowerCase().indexOf(needle) !== -1;
          item.classList.toggle('is-hidden', !hit);
        });
      });
    }
  });

  function closeAll(except) {
    pickers.forEach(function (p) {
      if (p !== except) p.open = false;
    });
  }

  // Only one picker open at a time, and clicking the page closes them.
  form.addEventListener('click', function (e) {
    var picker = e.target.closest('.picker');
    if (picker) {
      if (e.target.closest('summary')) closeAll(picker);
      return;
    }
    closeAll(null);
  });

  document.addEventListener('click', function (e) {
    if (!form.contains(e.target)) closeAll(null);
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') closeAll(null);
  });

  // The destination field's label and placeholder follow the alert type.
  var type = document.getElementById('alert-type');
  var label = document.getElementById('alert-target-label');
  var target = document.getElementById('alert-target');
  if (type && label && target) {
    type.addEventListener('change', function () {
      var opt = type.options[type.selectedIndex];
      label.textContent = opt.dataset.targetLabel;
      target.placeholder = opt.dataset.placeholder;
    });
  }

  // Time Frequency only matters once alert_count is "recurring".
  var count = document.getElementById('alert-count');
  var frequencyField = document.getElementById('alert-frequency-field');
  if (count && frequencyField) {
    var syncFrequency = function () {
      frequencyField.classList.toggle('is-hidden', count.value !== 'recurring');
    };
    count.addEventListener('change', syncFrequency);
    syncFrequency();
  }
})();
