// Tarang2_dp1 Lab — rebrands the stock noVNC connect screen logo.
//
// The "noVNC" logo text/title comes from the vendor vnc.html shipped by the
// apt `novnc` package (not something in this repo), and its exact markup
// varies across noVNC versions. Rather than hardcoding an ID/class that
// could break across a version bump, find whichever element's full trimmed
// text is exactly "noVNC" (covers the common two-span "no"+"VNC" split) and
// replace just that, in place — a no-op if no such element exists.
(function () {
  function relabel() {
    var all = document.querySelectorAll('*');
    var candidates = Array.prototype.filter.call(all, function (el) {
      return el.textContent.trim() === 'noVNC';
    });
    // Keep only the most specific (deepest) matches, in case an ancestor
    // also happens to have combined text "noVNC".
    var targets = candidates.filter(function (el) {
      return !candidates.some(function (other) {
        return other !== el && el.contains(other);
      });
    });
    targets.forEach(function (el) {
      el.textContent = 'Tarang2_dp1';
    });
    if (document.title.indexOf('noVNC') !== -1) {
      document.title = document.title.replace(/noVNC/g, 'Tarang2_dp1');
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', relabel);
  } else {
    relabel();
  }
})();
