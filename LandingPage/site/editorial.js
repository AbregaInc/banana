// Editorial pages: autoplay hero videos unless the reader prefers reduced motion, and open
// inline diagrams full size in a dialog. Everything works without this file; it only enhances.
(() => {
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  const videos = document.querySelectorAll("video[data-autoplay]");
  const sync = () => videos.forEach((video) => {
    if (reduced.matches) { video.pause(); video.autoplay = false; }
    else { video.autoplay = true; video.muted = true; video.play().catch(() => {}); }
  });
  sync(); reduced.addEventListener("change", sync);

  document.querySelectorAll("figure[data-diagram]").forEach((figure) => {
    const button = figure.querySelector(".diagram-open");
    const dialog = figure.nextElementSibling;
    const svg = button && button.querySelector("svg");
    if (!button || !svg || !dialog || dialog.tagName !== "DIALOG" || !dialog.showModal) return;
    const stage = dialog.querySelector(".diagram-stage");
    const open = () => { stage.append(svg); dialog.showModal(); };
    const close = () => dialog.close();
    button.addEventListener("click", open);
    // The caption link opens the same dialog; a modified click still opens the SVG file in a new tab.
    const link = figure.querySelector(".diagram-full");
    if (link) link.addEventListener("click", (event) => {
      if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault(); open();
    });
    dialog.querySelector(".diagram-close").addEventListener("click", close);
    dialog.addEventListener("click", (event) => { if (event.target === dialog) close(); });
    dialog.addEventListener("close", () => button.append(svg));
  });
})();
