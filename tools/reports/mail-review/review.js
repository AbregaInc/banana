import { buildPreview, makeAnchor } from "./preview.js";

const $ = id => document.getElementById(id);
const width = $("width");
const images = $("images");
const dialog = $("note-dialog");
const noteBody = $("note-body");
const noteError = $("note-error");
let catalog, current, draft, placing, statusTimer;
let panel;
let saving = false;
const settings = new URLSearchParams(location.search);
const requestedWidth = settings.get("width");
if ([...width.options].some(option => option.value === requestedWidth)) width.value = requestedWidth;
else if (matchMedia("(max-width: 760px)").matches) width.value = "320";
images.checked = settings.get("images") === "1";

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function button(text, onClick) {
  const node = element("button", text);
  node.type = "button";
  node.addEventListener("click", onClick);
  return node;
}

function announce(message) {
  clearTimeout(statusTimer);
  $("status").textContent = message;
  if (message) statusTimer = setTimeout(() => { $("status").textContent = ""; }, 4500);
}

function reviewFor(item = current) {
  return catalog.reviews[item.id]?.[item.revision] ?? { vote: null, notes: [] };
}

function renderMarkers(panel) {
  panel.markers.replaceChildren();
  if (!panel.elements) return;
  for (const [index, note] of reviewFor().notes.entries()) {
    if (note.width !== Number(width.value)
      || note.images !== images.checked || !note.anchor) continue;
    const target = panel.elements[note.anchor.element];
    if (!target) continue;
    const rect = target.getBoundingClientRect();
    const x = rect.left + rect.width * note.anchor.x;
    const y = rect.top + rect.height * note.anchor.y;
    if (!rect.width || !rect.height || x < 0 || y < 0
      || x >= panel.frame.clientWidth || y >= panel.frame.clientHeight) continue;
    const marker = element("span", String(index + 1), "marker");
    marker.style.left = `${x}px`;
    marker.style.top = `${y}px`;
    panel.markers.append(marker);
  }
}

function setPlacing(active = false) {
  if (!panel) return;
  placing = active ? panel : null;
  panel.box.dataset.placing = String(active);
  panel.pin.setAttribute("aria-pressed", String(active));
  panel.hint.hidden = !active;
  if (panel.frame.contentDocument?.body) {
    panel.frame.contentDocument.body.style.cursor = active ? "crosshair" : "";
  }
}

function buildPanel(item) {
  const box = element("section", "", "candidate");
  const header = element("header");
  const actions = element("div", "", "candidate-actions");
  const bed = element("div", "", "preview-bed");
  const preview = element("div", "", "preview-box");
  const hint = element("p", "Click the preview to place a pin. Press Esc to cancel.", "pin-hint");
  hint.hidden = true;
  const frame = element("iframe");
  frame.title = `${item.title} email preview`;
  frame.setAttribute("sandbox", "allow-same-origin");
  const markers = element("div", "", "markers");
  markers.setAttribute("aria-hidden", "true");
  const panel = { box, frame, markers, hint };
  const pin = button("Pin a note", () => setPlacing(placing !== panel));
  pin.setAttribute("aria-pressed", "false");
  panel.pin = pin;
  const add = button("Add a note", () => openNote());
  actions.append(add, pin);
  header.append(actions);
  preview.append(frame, markers);
  bed.append(preview);
  box.append(header, hint, bed);

  panel.ready = new Promise(resolve => {
    frame.addEventListener("load", () => {
      const view = frame.contentDocument;
      if (!view || frame.contentWindow.location.pathname !== `/preview/${item.id}`) {
        resolve();
        return;
      }
      view.addEventListener("click", event => {
        if (event.target.closest("a")) event.preventDefault();
        if (placing !== panel) return;
        const anchor = makeAnchor(view, event);
        if (anchor) openNote(anchor);
      });
      view.addEventListener("auxclick", event => event.preventDefault());
      view.addEventListener("contextmenu", event => {
        if (event.target.closest("a")) event.preventDefault();
      });
      view.addEventListener("keydown", cancelPlacing);
      Object.assign(panel, buildPreview(view, images.checked));
      frame.contentWindow.addEventListener("scroll", () => scheduleMarkers(panel), { passive: true });
      for (const picture of view.images) picture.addEventListener("load", () => scheduleMarkers(panel), { once: true });
      renderMarkers(panel);
      resolve();
    }, { once: true });
  });
  frame.src = `/preview/${item.id}`;
  return panel;
}

function scheduleMarkers(panel) {
  if (panel.frameRequest) return;
  panel.frameRequest = requestAnimationFrame(() => {
    panel.frameRequest = null;
    renderMarkers(panel);
  });
}

function cancelPlacing(event) {
  if (event.key === "Escape" && placing) {
    placing.pin.focus();
    setPlacing();
  }
}

function showPreview(keepScroll = false) {
  const position = keepScroll ? panel?.frame.contentWindow.scrollY : null;
  setPlacing();
  $("comparison").dataset.width = width.value;
  $("jump-change").disabled = true;
  const next = buildPanel(current);
  panel = next;
  $("comparison").replaceChildren(next.box);
  next.ready.then(() => {
    if (panel !== next) return;
    $("jump-change").disabled = !panel.changes?.length;
    if (position != null) panel.frame.contentWindow.scrollTo(0, position);
  });
}

function jumpToChange() {
  const target = panel.elements?.[panel.changes?.[0]];
  if (target?.getClientRects().length) {
    panel.frame.contentWindow.scrollBy(0, target.getBoundingClientRect().top);
  }
}
$("jump-change").addEventListener("click", jumpToChange);

async function jumpTo(note) {
  if (Number(width.value) !== note.width || images.checked !== note.images) {
    width.value = note.width;
    images.checked = note.images;
    showPreview();
  }
  const next = panel;
  await next.ready;
  if (panel !== next) return;
  const target = panel.elements?.[note.anchor.element];
  if (!target?.getClientRects().length) {
    announce("This spot is unavailable in the preview.");
    return;
  }
  panel.box.scrollIntoView({ block: "nearest" });
  const rect = target.getBoundingClientRect();
  const view = panel.frame.contentWindow;
  view.scrollBy(
    rect.left + rect.width * note.anchor.x - view.innerWidth / 2,
    rect.top + rect.height * note.anchor.y - view.innerHeight / 2
  );
  panel.pin.focus({ preventScroll: true });
}

function renderNotes() {
  const notes = reviewFor().notes.map((note, index) => {
    const item = element("li");
    const detail = [`${note.width} px`, note.images ? "Sample images" : "Text only"];
    item.append(element("p", detail.join(" · "), "note-detail"), element("p", note.body, "note-text"));
    if (note.anchor) {
      if (note.anchor.excerpt) item.append(element("p", note.anchor.excerpt, "note-detail"));
      item.append(button(`Show pin ${index + 1}`, () => jumpTo(note)));
    }
    return item;
  });
  $("notes").replaceChildren(...notes);
  renderMarkers(panel);
}

function selectCase(item) {
  current = item;
  history.replaceState(null, "", `#${item.id}`);
  $("case-title").textContent = item.title;
  for (const tab of $("cases").querySelectorAll("button")) {
    if (tab.dataset.case === item.id) tab.setAttribute("aria-current", "page");
    else tab.removeAttribute("aria-current");
  }
  showPreview();
  renderNotes();
}

async function save(action) {
  const item = current;
  const response = await fetch("/api/review", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...action, case: item.id, revision: item.revision }),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error);
  (catalog.reviews[item.id] ??= {})[item.revision] = result;
  if (item === current) renderNotes();
}

function noteID() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function openNote(anchor = null) {
  setPlacing();
  draft = { anchor, width: Number(width.value), images: images.checked, id: noteID() };
  $("note-context").textContent = [`${width.value} px`, anchor?.excerpt].filter(Boolean).join(" · ");
  noteError.textContent = "";
  noteBody.value = "";
  dialog.showModal();
  noteBody.focus();
}

$("cancel-note").addEventListener("click", () => dialog.close());
dialog.addEventListener("cancel", event => {
  if (saving) event.preventDefault();
});
$("note-form").addEventListener("submit", async event => {
  event.preventDefault();
  if (saving) return;
  saving = true;
  const controls = [...$("note-form").querySelectorAll("button, textarea")];
  controls.forEach(control => { control.disabled = true; });
  noteError.textContent = "";
  try {
    await save({ ...draft, type: "note", body: noteBody.value });
    dialog.close();
    announce("Note saved");
  } catch (error) {
    noteError.textContent = error.message || "Could not save the note. Try again.";
  } finally {
    saving = false;
    controls.forEach(control => { control.disabled = false; });
    if (dialog.open) noteBody.focus();
  }
});

document.addEventListener("keydown", cancelPlacing);
width.addEventListener("change", () => showPreview(true));
images.addEventListener("change", () => showPreview(true));
window.addEventListener("resize", () => { if (panel) scheduleMarkers(panel); }, { passive: true });

try {
  const response = await fetch("/api/review");
  if (!response.ok) throw new Error("Could not load newsletters.");
  catalog = await response.json();
  for (const item of catalog.cases) {
    const tab = button(item.title, () => selectCase(item));
    tab.dataset.case = item.id;
    $("cases").append(tab);
  }
  $("workspace").hidden = false;
  const requested = catalog.cases.find(item => `#${item.id}` === location.hash);
  $("progress").hidden = true;
  selectCase(requested ?? catalog.cases[0]);
} catch (error) {
  $("progress").textContent = error.message || "Could not load newsletters.";
}
