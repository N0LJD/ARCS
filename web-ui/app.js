/* app.js
 * ARCS Web UI (two-tier):
 * - Builds requests to /xml.php?action=search
 * - Fetches XML (same-origin via /api reverse proxy)
 * - Parses <results><item> into a table
 * - Supports paging via offset + limit
 *
 * Namespace note:
 * The API XML includes a default namespace (xmlns="https://www.hamqth.com").
 * We therefore parse using getElementsByTagNameNS("*", ...) to be namespace-agnostic.
 */

function $(id) { return document.getElementById(id); }

function getBase() {
  const base = (window.UI_API_BASE_URL || "").trim().replace(/\/+$/, "");
  return base || "/api";
}

function norm(s) { return (s || "").trim(); }

function countConstraints({ callsign, name, city, state, zip }) {
  return [callsign, name, city, state, zip].filter(v => norm(v)).length;
}

function callsignOnlyAllowed({ callsign, name, city, state, zip }) {
  return norm(callsign) && !norm(name) && !norm(city) && !norm(state) && !norm(zip);
}

function setMessage(msg) { $("msg").textContent = msg || ""; }
function setWarn(msg) { $("warn").textContent = msg || ""; }
function setError(msg) { $("err").textContent = msg || ""; }
function setPageStatus(msg) { $("pageStatus").textContent = msg || ""; }
function clearMessages() { setMessage(""); setWarn(""); setError(""); }

function getLimit() { return $("limit").value; }
function getOffset() { return parseInt($("offset").value || "0", 10) || 0; }
function setOffset(v) { $("offset").value = String(Math.max(0, v|0)); }

function getQueryInputs() {
  return {
    callsign: norm($("callsign").value),
    name: norm($("name").value),
    city: norm($("city").value),
    state: norm($("state").value).toUpperCase(),
    zip: norm($("zip").value),
  };
}

/* ---------------------------
 * Namespace-safe XML helpers
 * --------------------------- */
function firstByLocal(parent, name) {
  const nodes = parent.getElementsByTagNameNS("*", name);
  return nodes && nodes.length ? nodes[0] : null;
}
function allByLocal(parent, name) {
  const nodes = parent.getElementsByTagNameNS("*", name);
  return nodes ? Array.from(nodes) : [];
}
function textByLocal(parent, name) {
  const el = firstByLocal(parent, name);
  return el ? (el.textContent || "").trim() : "";
}

/* ---------------------------
 * URL builder with guardrails
 * --------------------------- */
function buildUrl({ overrideOffset = null } = {}) {
  const base = getBase();
  const params = new URLSearchParams();
  params.set("action", "search");

  const q = getQueryInputs();
  const isCallsignOnly = callsignOnlyAllowed(q);

  // Callsign-only: exact-match intent.
  // - We still use the same endpoint (action=search), but we make the UI expectations clear:
  //   wildcard '*' is not accepted in callsign-only mode.
  if (isCallsignOnly && q.callsign.includes("*")) {
    // Don’t throw; just warn and strip wildcard to keep user intent "exact match".
    setWarn("Callsign-only searches use exact match. Wildcard '*' was removed. Add another field to use wildcard.");
    q.callsign = q.callsign.replace(/\*/g, "");
    $("callsign").value = q.callsign;
  }

  if (q.callsign) params.set("callsign", q.callsign);
  if (q.name) params.set("name", q.name);
  if (q.city) params.set("city", q.city);
  if (q.state) params.set("state", q.state);
  if (q.zip) params.set("zip", q.zip);

  const limit = getLimit();
  if (limit !== "") params.set("limit", limit);

  const off = (overrideOffset === null) ? getOffset() : overrideOffset;
  if (off && off > 0) params.set("offset", String(off));

  return { url: `${base}/xml.php?${params.toString()}`, isCallsignOnly };
}

function renderRows(items) {
  const tbody = $("tbody");
  tbody.innerHTML = "";

  if (!items.length) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = 11;
    td.className = "muted";
    td.textContent = "No matches.";
    tr.appendChild(td);
    tbody.appendChild(tr);
    return;
  }

  for (const it of items) {
    const tr = document.createElement("tr");

    // Callsign cell opens callsign lookup XML in new tab
    {
      const td = document.createElement("td");
      const a = document.createElement("a");
      a.href = "#";
      a.textContent = it.callsign || "";
      a.title = "Open callsign lookup XML";
      a.addEventListener("click", (ev) => {
        ev.preventDefault();
        if (!it.callsign) return;
        const base = getBase().replace(/\/+$/, "");
        const url = `${base}/xml.php?callsign=${encodeURIComponent(it.callsign)}`;
        window.open(url, "_blank");
      });
      td.appendChild(a);
      tr.appendChild(td);
    }

    const cells = [
      it.adr_name,
      it.adr_street1,
      it.adr_city,
      it.adr_adrcode,
      it.adr_zip,
      it.status,
      it.operator_class_name || it.operator_class,
      it.grant_date,
      it.expired_date,
    ];

    for (const c of cells) {
      const td = document.createElement("td");
      td.textContent = c || "";
      tr.appendChild(td);
    }

    // XML link cell opens the current search XML in new tab
    {
      const td = document.createElement("td");
      const a = document.createElement("a");
      a.href = "#";
      a.textContent = "search";
      a.title = "Open this search XML";
      a.addEventListener("click", (ev) => {
        ev.preventDefault();
        window.open(buildUrl().url, "_blank");
      });
      td.appendChild(a);
      tr.appendChild(td);
    }

    tbody.appendChild(tr);
  }
}

function setPagingButtons({ limit, offset, returned, more }) {
  const lim = parseInt(limit || "0", 10) || 0;
  $("btnPrev").disabled = !(lim > 0 && offset > 0);
  $("btnNext").disabled = !(lim > 0 && String(more) === "1");

  if (lim === 0) {
    setPageStatus(`Paging disabled (limit=0). Returned ${returned}.`);
  } else {
    const page = Math.floor(offset / lim) + 1;
    setPageStatus(`Page ${page} • limit=${lim} • offset=${offset} • returned=${returned} • more=${more}`);
  }
}

async function doSearch({ resetOffset = false, openXml = false } = {}) {
  clearMessages();
  $("apiBase").textContent = getBase();

  if (resetOffset) setOffset(0);

  const q = getQueryInputs();
  const constraints = countConstraints(q);
  const isCallsignOnly = callsignOnlyAllowed(q);

  if (!isCallsignOnly && constraints < 2) {
    setWarn("Please provide at least two fields (name/city/state/zip), or callsign alone.");
    renderRows([]);
    setPagingButtons({ limit: getLimit(), offset: getOffset(), returned: 0, more: 0 });
    return;
  }

  const built = buildUrl({ overrideOffset: null });
  const url = built.url;

  // Mode indicator
  if (built.isCallsignOnly) {
    setMessage(`Mode: callsign-only (exact). Requesting: ${url}`);
  } else {
    setMessage(`Mode: multi-field (wildcards allowed). Requesting: ${url}`);
  }

  if (openXml) {
    window.open(url, "_blank");
    return;
  }

  try {
    const res = await fetch(url, { headers: { "Accept": "application/xml" } });
    const txt = await res.text();

    if (!res.ok) {
      setError(`HTTP ${res.status}\n\n${txt}`);
      renderRows([]);
      setPagingButtons({ limit: getLimit(), offset: getOffset(), returned: 0, more: 0 });
      return;
    }

    const parser = new DOMParser();
    const doc = parser.parseFromString(txt, "application/xml");

    const pe = doc.getElementsByTagName("parsererror")[0];
    if (pe) {
      setError("XML parse error (browser could not parse response).");
      renderRows([]);
      setPagingButtons({ limit: getLimit(), offset: getOffset(), returned: 0, more: 0 });
      return;
    }

    const session = firstByLocal(doc, "session");
    const err = session ? textByLocal(session, "error") : "";
    if (err && err !== "OK") {
      setError(`API error: ${err}`);
      renderRows([]);
      setPagingButtons({ limit: getLimit(), offset: getOffset(), returned: 0, more: 0 });
      return;
    }

    const search = firstByLocal(doc, "search");
    const returned = search ? textByLocal(search, "returned") : "0";
    const more = search ? textByLocal(search, "more") : "0";
    const limit = search ? textByLocal(search, "limit") : getLimit();
    const offset = search ? parseInt(textByLocal(search, "offset") || "0", 10) : getOffset();

    setOffset(offset);

    if (String(limit) === "0") {
      setWarn("limit=0 returns all matches; large searches may take a while (paging disabled).");
    }

    const results = firstByLocal(doc, "results");
    const itemNodes = results ? allByLocal(results, "item") : [];

    const items = itemNodes.map(node => ({
      callsign: textByLocal(node, "callsign"),
      adr_name: textByLocal(node, "adr_name"),
      adr_street1: textByLocal(node, "adr_street1"),
      adr_city: textByLocal(node, "adr_city"),
      adr_adrcode: textByLocal(node, "adr_adrcode"),
      adr_zip: textByLocal(node, "adr_zip"),
      status: textByLocal(node, "status"),
      operator_class: textByLocal(node, "operator_class"),
      operator_class_name: textByLocal(node, "operator_class_name"),
      grant_date: textByLocal(node, "grant_date"),
      expired_date: textByLocal(node, "expired_date"),
    }));

    renderRows(items);
    setPagingButtons({ limit, offset, returned, more });
  } catch (e) {
    setError(
      "TypeError: Failed to fetch\n\n" +
      "Checks:\n" +
      "  1) UI is reachable\n" +
      "  2) /api reverse proxy is working\n\n" +
      `Details: ${String(e)}`
    );
    renderRows([]);
    setPagingButtons({ limit: getLimit(), offset: getOffset(), returned: 0, more: 0 });
  }
}

function clearForm() {
  $("callsign").value = "";
  $("name").value = "";
  $("city").value = "";
  $("state").value = "";
  $("zip").value = "";
  $("limit").value = "100";
  setOffset(0);
  clearMessages();
  setPageStatus("");
  renderRows([]);
  $("btnPrev").disabled = true;
  $("btnNext").disabled = true;
}

document.addEventListener("DOMContentLoaded", () => {
  $("apiBase").textContent = getBase();

  $("btnSearch").addEventListener("click", () => doSearch({ resetOffset: true }));
  $("btnOpenXml").addEventListener("click", () => doSearch({ openXml: true }));

  $("btnPrev").addEventListener("click", () => {
    const lim = parseInt(getLimit() || "0", 10) || 0;
    if (lim <= 0) return;
    const off = getOffset();
    const nextOff = Math.max(0, off - lim);
    setOffset(nextOff);
    doSearch({ resetOffset: false });
  });

  $("btnNext").addEventListener("click", () => {
    const lim = parseInt(getLimit() || "0", 10) || 0;
    if (lim <= 0) return;
    const off = getOffset();
    const nextOff = off + lim;
    setOffset(nextOff);
    doSearch({ resetOffset: false });
  });

  $("btnClear").addEventListener("click", clearForm);

  renderRows([]);
});
