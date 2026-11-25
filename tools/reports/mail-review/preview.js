const headingTags = "h1,h2,h3,h4,h5,h6";
const displayedTags = new Set([
  "A", "B", "BLOCKQUOTE", "BR", "CAPTION", "CODE", "DD", "DL", "DT", "EM", "H1", "H2",
  "H3", "H4", "H5", "H6", "HR", "I", "LI", "OL", "P", "PRE", "STRONG", "UL",
]);
const tableTags = new Set(["TABLE", "THEAD", "TBODY", "TFOOT", "TR", "TD", "TH"]);
const ignoredTags = new Set(["STYLE", "SCRIPT", "NOSCRIPT", "TEMPLATE"]);
const typography = `
  html, body { margin: 0; background: white; color: #22272b; }
  body { font: 16px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
  .message { box-sizing: border-box; padding: 12px 15px 24px; min-width: 0; }
  p { margin: 0 0 .65em; }
  h1, h2, h3, h4, h5, h6 { font-size: 1em; line-height: 1.4; margin: 0; }
  a { color: #19588f; text-decoration: underline; text-underline-offset: 2px; }
  img { display: block; max-width: 100%; height: auto; margin: .35em 0 .75em; }
  ul, ol { padding-inline-start: 1.35em; }
  .parts { margin: .65em 0 1em; }
  .parts > li + li { margin-block-start: .25em; }
  .parts p { margin: 0; }
  .parts > li > .part-heading + :is(p, .part-heading) { display: inline; margin-inline-start: .4em; }
  .linked-section { margin-block: .8em; }
  .linked-section .section-link { display: block; margin-block-end: .25em; font-weight: 650; }
  .inline-row { line-height: 1.5; }
  .inline-row > span { display: inline; }
  .inline-row > span div { display: inline; }
  .part-heading { font-weight: 650; }
  .image-link { display: inline-block; }
  pre { white-space: pre-wrap; }
  blockquote { margin: .65em 0 .65em .7em; padding-inline-start: .7em; border-inline-start: 2px solid #d5dbe0; }
  hr { border: 0; border-top: 1px solid #d5dbe0; }
  .data-table { max-width: 100%; overflow-x: auto; }
  table { border-collapse: collapse; }
  th, td { vertical-align: top; text-align: start; padding: .25em .45em; }
`;

function visible(document, element) {
  const style = document.defaultView.getComputedStyle(element);
  return style.visibility === "visible" && style.opacity !== "0"
    && element.getClientRects().length > 0;
}

function meaningfulAlt(image) {
  const alt = (image.getAttribute("alt") || "").trim();
  return /^(?:image|photo|spacer|pixel|icon|logo)$/i.test(alt) ? "" : alt;
}

function largerImage(image) {
  const width = Number(image.getAttribute("width"));
  const height = Number(image.getAttribute("height"));
  return (!width || width >= 120) && (!height || height >= 60);
}

function sampleArt() {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180" viewBox="0 0 320 180"><rect width="320" height="180" fill="#e5e9e0"/><circle cx="236" cy="46" r="19" fill="#e6c7a0"/><path fill="#a3b8a8" d="M0 128 98 48l102 94 48-42 72 55v25H0z"/><path fill="#c1cfbc" d="M0 160l96-54 75 61 67-21 82 27v7H0z"/></svg>';
  return "data:image/svg+xml," + encodeURIComponent(svg);
}

function hasDataSemantics(table) {
  return table.getAttribute("role") !== "presentation" && (Boolean(table.caption) ||
    Boolean(table.tHead) || [...table.rows].some(row => [...row.cells].some(cell => cell.tagName === "TH")));
}

function removeAdjacentIconLinks(row) {
  const links = [...row.querySelectorAll("a[href]")];
  for (const [index, icon] of links.entries()) {
    if (!icon.dataset.imageLink || icon.querySelector("img")) continue;
    const neighbors = [links[index - 1], links[index + 1]];
    if (!neighbors.some(link => link && !link.dataset.imageLink && link.textContent.trim()
      && link.getAttribute("href") === icon.getAttribute("href"))) continue;
    const cell = icon.closest(".inline-row > span");
    icon.remove();
    if (cell && !cell.textContent.trim() && !cell.querySelector("img")) cell.remove();
  }
}

// Project only what the sender's narrow template actually displays. Keep the same source
// anchor IDs so pins remain attached to the text or link the reviewer saw.
export function buildPreview(document, images) {
  const source = [...document.body.querySelectorAll("*")];
  const ids = new Map(source.map((node, index) => [node, index]));
  const targets = new Array(source.length);
  const changes = [];
  const artwork = images ? sampleArt() : null;
  const partHeadings = new Set();
  const semanticTables = new Set([...document.querySelectorAll("table")].filter(hasDataSemantics));
  const message = document.createElement("article");
  message.className = "message";

  function newNode(original, tag) {
    const copy = document.createElement(tag);
    const id = ids.get(original);
    copy.dataset.reviewAnchor = id;
    targets[id] = copy;
    return copy;
  }

  function children(original, target, state) {
    for (const child of original.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) {
        if (child.textContent) target.append(document.createTextNode(child.textContent));
      }
      if (child.nodeType === Node.ELEMENT_NODE) {
        const copy = project(child, state);
        if (copy) target.append(copy);
      }
    }
  }

  function picture(node, state) {
    const alt = meaningfulAlt(node);
    const displayed = node.getBoundingClientRect();
    if (!state.background && (displayed.width <= 2 || displayed.height <= 2)) return null;
    if (artwork && largerImage(node) && (alt || state.link)) {
      const result = newNode(node, "img");
      result.alt = alt;
      result.src = artwork;
      return result;
    }
    if (!state.background && alt && largerImage(node) && !state.linkHasText) {
      const result = newNode(node, "span");
      result.textContent = alt;
      return result;
    }
    return null;
  }

  function project(node, state) {
    if (ignoredTags.has(node.tagName) || node.getAttribute("aria-hidden") === "true" || !visible(document, node)) return null;
    if (node.tagName === "IMG") return picture(node, state);
    const { tagName } = node;
    const ownTable = tagName === "TABLE" ? node : state.table;
    const semantic = semanticTables.has(ownTable);
    const link = tagName === "A" && node.hasAttribute("href");
    const linkState = link ? { ...state, link: true, linkHasText: Boolean(node.innerText.trim()) } : state;
    const background = state.link && tagName === "TD" && /^url\(/i.test(node.style.backgroundImage)
      && [...node.querySelectorAll("img[alt]")].find(image => meaningfulAlt(image) && largerImage(image));
    if (background) {
      changes.push(ids.get(node.closest("a")));
      const result = newNode(node, "div");
      if (artwork) {
        const sample = picture(background, { ...state, background: true });
        if (sample) result.append(sample);
      }
      return result;
    }

    const headedParts = !semantic && tagName === "TR" && node.cells.length > 1
      && [...node.cells].every(cell => {
        const head = [...cell.children].find(child => child.matches(headingTags) && visible(document, child));
        return Boolean(head) && visible(document, cell);
      });
    if (headedParts) {
      changes.push(ids.get(node));
      const result = newNode(node, "ul");
      result.className = "parts";
      for (const cell of node.cells) {
        const part = newNode(cell, "li");
        const headlines = [...cell.children].filter(child => child.matches(headingTags) && visible(document, child));
        headlines.forEach(headline => partHeadings.add(headline));
        children(cell, part, { ...state, table: ownTable });
        result.append(part);
      }
      return result;
    }

    const textTag = displayedTags.has(tagName) || (semantic && tableTags.has(tagName));
    // Layout tables often make the entire story one anchor. Keep the destination on a
    // short piece of text; paragraphs and metadata should read as prose.
    const compactLink = link && Boolean(node.querySelector("table"));
    const tag = partHeadings.has(node) || tagName === "SPAN" ? "span"
      : compactLink ? "div" : textTag ? tagName.toLowerCase() : "div";
    let copy = newNode(node, tag);
    if (partHeadings.has(node)) copy.className = "part-heading";
    if (!semantic && tagName === "TD") copy.classList.add("layout-cell");
    if (link && !compactLink) {
      copy.setAttribute("href", node.getAttribute("href"));
      if (!linkState.linkHasText && node.querySelector("img")) copy.dataset.imageLink = "true";
    }
    if (tagName === "TD" || tagName === "TH") {
      if (semantic && node.colSpan > 1) copy.colSpan = node.colSpan;
      if (semantic && node.rowSpan > 1) copy.rowSpan = node.rowSpan;
    }
    children(node, copy, { ...linkState, table: ownTable });
    if (compactLink) {
      const titleSelectors = [headingTags, "p", ".layout-cell"];
      const title = titleSelectors.flatMap(selector => [...copy.querySelectorAll(selector)]).find(element =>
        /[\p{L}\p{N}]/u.test(element.textContent) && !element.closest("a")
        && !element.querySelector("a,.layout-cell,ul,ol,table,img")
      );
      const href = node.getAttribute("href");
      const equivalent = [...copy.querySelectorAll("a[href]")].find(
        action => action.getAttribute("href") === href && (action.textContent.trim() || action.querySelector("img"))
      );
      if (equivalent) return copy;
      const action = document.createElement("a");
      action.setAttribute("href", href);
      copy.className = "linked-section";
      if (title) {
        action.append(...title.childNodes);
        title.append(action);
        title.classList.add("section-link");
      } else {
        const alternative = [...node.querySelectorAll("img[alt]")].map(meaningfulAlt).find(Boolean);
        action.textContent = alternative || "Open link";
        copy.append(action);
      }
    }
    if (!semantic && tagName === "TR" && node.cells.length > 1
      && [...node.cells].every(cell => !cell.querySelector(`table,p,ul,ol,${headingTags}`))
      && !copy.querySelector("img") && copy.textContent.trim()) {
      copy.classList.add("inline-row");
      for (const cell of [...copy.children]) {
        const inline = document.createElement("span");
        inline.dataset.reviewAnchor = cell.dataset.reviewAnchor;
        targets[Number(inline.dataset.reviewAnchor)] = inline;
        if (!cell.textContent.trim()) {
          cell.remove();
          continue;
        }
        inline.append(...cell.childNodes);
        if (cell.previousElementSibling) cell.before(document.createTextNode(" "));
        cell.replaceWith(inline);
      }
      removeAdjacentIconLinks(copy);
    }
    if (link && !copy.textContent.trim() && !copy.querySelector("img")) {
      const alternative = [...node.querySelectorAll("img[alt]")].map(meaningfulAlt).find(Boolean);
      copy.textContent = alternative || "Image link";
      copy.className = "image-link";
    }
    if (semantic && tagName === "TABLE") {
      const wrapper = document.createElement("div");
      wrapper.className = "data-table";
      wrapper.append(copy);
      return wrapper;
    }
    return copy;
  }

  children(document.body, message, { table: null, link: false, linkHasText: false });
  document.querySelectorAll("style").forEach(style => style.remove());
  const style = document.createElement("style");
  style.textContent = typography;
  document.head.append(style);
  document.body.replaceChildren(message);
  return { elements: targets, changes: [...new Set(changes)] };
}

export function makeAnchor(document, event) {
  const target = event.target.closest("[data-review-anchor]");
  if (!target || !visible(document, target)) return null;
  const rect = target.getBoundingClientRect();
  if (!rect.width || !rect.height) return null;
  const excerpt = target.getAttribute("alt") || target.innerText || "";
  const fraction = (value, start, size) => Math.max(0, Math.min(1, (value - start) / size));
  return {
    element: Number(target.dataset.reviewAnchor),
    x: fraction(event.clientX, rect.left, rect.width),
    y: fraction(event.clientY, rect.top, rect.height),
    excerpt: excerpt.replace(/\s+/g, " ").trim().slice(0, 160),
  };
}
