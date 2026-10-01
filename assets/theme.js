/* Ground Truth — adaptive theme toggle
   Default: follow the OS (system-auto). An explicit choice via the button
   is saved to localStorage ('gt-theme') and wins over the OS until cleared.
   The no-flash setter lives inline in each page <head>; this file injects
   the toggle button into .site-nav and keeps it in sync. */
(function () {
  var KEY = "gt-theme";
  var SUN =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M19 5l-1.5 1.5M6.5 17.5 5 19"/></svg>';
  var MOON =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>';

  function mql() { return window.matchMedia("(prefers-color-scheme: dark)"); }
  function current() {
    var x = document.documentElement.getAttribute("data-theme");
    if (x === "light" || x === "dark") return x;
    return mql().matches ? "dark" : "light";
  }

  function init() {
    var nav = document.querySelector(".site-nav") || document.querySelector(".site-head-inner");
    if (!nav || document.getElementById("gtThemeToggle")) return;

    var btn = document.createElement("button");
    btn.id = "gtThemeToggle";
    btn.className = "theme-toggle";
    btn.type = "button";

    function paint() {
      var dark = current() === "dark";
      btn.innerHTML = dark ? SUN : MOON;
      btn.setAttribute("aria-label", dark ? "Switch to light theme" : "Switch to dark theme");
      btn.setAttribute("title", dark ? "Light mode" : "Dark mode");
    }
    function set(t) {
      document.documentElement.setAttribute("data-theme", t);
      try { localStorage.setItem(KEY, t); } catch (e) {}
      paint();
    }

    btn.addEventListener("click", function () {
      set(current() === "dark" ? "light" : "dark");
    });
    nav.appendChild(btn);
    paint();

    // if no explicit choice is set, follow OS changes live
    var m = mql();
    var onChange = function () {
      if (!document.documentElement.getAttribute("data-theme")) paint();
    };
    if (m.addEventListener) m.addEventListener("change", onChange);
    else if (m.addListener) m.addListener(onChange);
  }

  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", init);
  else init();
})();
