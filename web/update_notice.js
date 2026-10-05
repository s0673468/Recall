// A waiting worker is ready for a future launch. Inform the learner without
// activating it, reloading the page, or touching their durable pending writes.
(function () {
  'use strict';
  var metadata = document.querySelector('meta[name="recall-build"]');
  var version = metadata && metadata.content;
  var label = /^[0-9a-f]{40}$/.test(version || '')
    ? 'Website build ' + version.slice(0, 7)
    : 'Development build';
  var splashVersion = document.getElementById('recall-splash-version');
  if (splashVersion) splashVersion.textContent = label;

  var notice = document.getElementById('recall-update-notice');
  var dismiss = document.getElementById('recall-dismiss-update');
  var dismissed = false;
  if (dismiss) dismiss.addEventListener('click', function () {
    dismissed = true;
    if (notice) notice.hidden = true;
  });

  window.recallWatchWebUpdates = function (registration) {
    var watched = new WeakSet();
    function showWaiting() {
      // A first installation supplies offline support, rather than an update
      // to this running session. Only controlled pages get the notice.
      if (!dismissed && notice && navigator.serviceWorker.controller &&
          registration.waiting) notice.hidden = false;
    }
    function watchInstalling() {
      showWaiting();
      var worker = registration.installing;
      if (!worker || watched.has(worker)) return;
      watched.add(worker);
      worker.addEventListener('statechange', showWaiting);
    }
    registration.addEventListener('updatefound', watchInstalling);
    watchInstalling();
  };
})();
