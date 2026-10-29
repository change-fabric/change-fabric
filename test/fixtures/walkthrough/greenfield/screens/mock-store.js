// cf:prototype mock store. Copy into walkthrough/<slug>/screens/mock-store.js.
// Vanilla JS, no dependencies, no build step, and no network: no fetch, no
// XHR, no WebSocket. State lives in localStorage under "cf-mock" (or memory
// when storage is unavailable) and starts from window.__CF_SEED__, which the
// capture injects, or from an inline <script type="application/json"
// id="cf-seed"> copy of data/seed.json when a screen is opened by hand.
// Ids and timestamps come from Date and Math.random, which the capture's
// controlled clock and seeded PRNG make deterministic.
(function () {
  "use strict";
  var KEY = "cf-mock";
  var memory = null;
  var listeners = [];

  function storage() {
    try { var s = window.localStorage; s.getItem(KEY); return s; } catch (err) { return null; }
  }

  function clone(value) { return value === undefined ? undefined : JSON.parse(JSON.stringify(value)); }

  function initialState() {
    if (window.__CF_SEED__) return clone(window.__CF_SEED__);
    var inline = document.getElementById("cf-seed");
    if (inline) { try { return JSON.parse(inline.textContent); } catch (err) { return {}; } }
    return {};
  }

  function load() {
    var s = storage();
    if (s) {
      var raw = s.getItem(KEY);
      if (raw) { try { return JSON.parse(raw); } catch (err) { /* fall through to seed */ } }
      var seeded = initialState();
      s.setItem(KEY, JSON.stringify(seeded));
      return seeded;
    }
    if (!memory) memory = initialState();
    return memory;
  }

  function save(state) {
    var s = storage();
    if (s) s.setItem(KEY, JSON.stringify(state)); else memory = state;
    listeners.forEach(function (fn) { try { fn(state); } catch (err) { void err; } });
  }

  function parts(path) { return String(path || "").split(".").filter(Boolean); }

  function walk(state, keys, create) {
    var node = state;
    for (var i = 0; i < keys.length; i++) {
      if (node[keys[i]] === undefined || node[keys[i]] === null) {
        if (!create) return undefined;
        node[keys[i]] = /^\d+$/.test(keys[i + 1] || "") ? [] : {};
      }
      node = node[keys[i]];
    }
    return node;
  }

  function get(path) {
    var keys = parts(path);
    if (!keys.length) return clone(load());
    return clone(walk(load(), keys, false));
  }

  function set(path, value) {
    var state = load();
    var keys = parts(path);
    var last = keys.pop();
    walk(state, keys, true)[last] = clone(value);
    save(state);
    return value;
  }

  function push(path, value) {
    var state = load();
    var list = walk(state, parts(path), true);
    if (!Array.isArray(list)) throw new Error("CFStore.push: " + path + " is not a list");
    list.push(clone(value));
    save(state);
    return list.length;
  }

  function remove(path) {
    var state = load();
    var keys = parts(path);
    var last = keys.pop();
    var parent = walk(state, keys, false);
    if (!parent) return false;
    if (Array.isArray(parent)) parent.splice(Number(last), 1); else delete parent[last];
    save(state);
    return true;
  }

  function subscribe(fn) {
    listeners.push(fn);
    return function () { listeners = listeners.filter(function (l) { return l !== fn; }); };
  }

  function nextId(prefix) {
    var rand = Math.floor(Math.random() * 0x100000).toString(36);
    return (prefix || "id") + "-" + Date.now().toString(36) + rand;
  }

  function dump() { return clone(load()); }

  function reset() { var s = storage(); if (s) s.removeItem(KEY); memory = null; save(load()); }

  // <template data-cf-list="invoices"> renders one clone per item into its
  // parent; [data-cf-field="name"] inside it receives item.name as text.
  // [data-cf-count="invoices"] shows the list length; [data-cf-empty="invoices"]
  // shows only while the list is empty.
  function render() {
    document.querySelectorAll("template[data-cf-list]").forEach(function (tpl) {
      var items = get(tpl.getAttribute("data-cf-list")) || [];
      var parent = tpl.parentNode;
      parent.querySelectorAll("[data-cf-item]").forEach(function (el) { el.remove(); });
      items.forEach(function (item, index) {
        var frag = tpl.content.cloneNode(true);
        frag.querySelectorAll("[data-cf-field]").forEach(function (el) {
          var value = walk(item, parts(el.getAttribute("data-cf-field")), false);
          el.textContent = value === undefined ? "" : String(value);
        });
        Array.prototype.forEach.call(frag.children, function (el) { el.setAttribute("data-cf-item", String(index)); });
        parent.appendChild(frag);
      });
    });
    document.querySelectorAll("[data-cf-count]").forEach(function (el) {
      var list = get(el.getAttribute("data-cf-count")) || [];
      el.textContent = String(list.length);
    });
    document.querySelectorAll("[data-cf-empty]").forEach(function (el) {
      var list = get(el.getAttribute("data-cf-empty")) || [];
      el.hidden = list.length > 0;
    });
  }

  // <form data-cf-submit="invoices" data-cf-toast="#saved"> pushes its named
  // fields, plus a generated id and createdAt, onto that list.
  function wireForms() {
    document.addEventListener("submit", function (event) {
      var form = event.target;
      if (!form || !form.hasAttribute || !form.hasAttribute("data-cf-submit")) return;
      event.preventDefault();
      var record = { id: nextId(form.getAttribute("data-cf-prefix")), createdAt: new Date().toISOString() };
      Array.prototype.forEach.call(form.elements, function (el) {
        if (el.name) record[el.name] = el.type === "checkbox" ? el.checked : el.value;
      });
      push(form.getAttribute("data-cf-submit"), record);
      form.reset();
      var toast = form.getAttribute("data-cf-toast");
      if (toast) { var el = document.querySelector(toast); if (el) el.hidden = false; }
    });
  }

  window.CFStore = { get: get, set: set, push: push, remove: remove, subscribe: subscribe,
    nextId: nextId, dump: dump, reset: reset, render: render };
  subscribe(render);
  wireForms();
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", render); else render();
})();
