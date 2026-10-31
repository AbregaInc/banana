// A small shell; all personal content comes from authenticated, non-cacheable reads.
export function page({ homePath = "/app/" } = {}) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow"><meta name="theme-color" content="#fbf6ea">
<meta name="app-home" content="${homePath}">
<title>Banana · Your space</title>
<link rel="icon" href="/app/assets/favicon-48.png?v=dimensional82"><link rel="preload" href="/book/fonts/IBMPlexMono-400.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/app/assets/app.css"><script type="module" src="/app/assets/app.js"></script>
</head><body><a class="skip" href="#main">Skip to content</a>
<header class="topbar"><a class="brand" href="https://bananatheapp.com"><img src="/app/assets/mark.svg?v=dimensional82" width="30" height="30" alt="">Banana</a>
<div id="account-controls" hidden><button class="text-button" id="refresh">Refresh</button><button class="text-button" id="signout">Sign out</button></div></header>
<div id="login" hidden><main class="welcome" id="welcome"><span class="eyebrow" id="login-kicker">A LITTLE MORE ROOM FOR YOUR DAY</span><h1 id="login-title">All yours.<br>Anywhere.</h1><p id="login-description">Your plans, meals, workouts and listening.<br>The same Banana, in your browser.</p>
<a class="button" id="google-signin" href="/app/auth/google">Continue with Google <span aria-hidden="true">↗</span></a><p class="fine" id="login-hint">Use a Google account connected to Banana or invited to a shared view.</p><p class="login-error" id="login-error" role="alert" hidden></p>
<div class="welcome-bottom"><span>FROM YOUR DEVICES. TO YOUR DESK.</span><a href="https://bananatheapp.com/privacy">Privacy</a></div></main></div>
<div id="share-banner" class="share-banner" hidden></div>
<div id="shared-home" hidden></div>
<div id="workspace" class="workspace" hidden><aside class="sidebar"><div><nav id="navigation" aria-label="Your data"></nav></div><div class="sidebar-bottom"><span class="status-dot"></span><span id="sync-source-label">From your devices</span><p id="sync-time"></p><p id="account-email"></p></div></aside>
<main id="main" tabindex="-1"><div class="page-heading"><div><p id="page-kicker" class="eyebrow"></p><h1 id="page-title">Your space</h1><p id="page-description" class="description"></p></div><span id="page-date" class="date-label"></span></div>
<p id="notice" class="notice" role="status" hidden></p><div class="tools" id="tools" hidden><label class="search"><span aria-hidden="true">⌕</span><input type="search" id="search" placeholder="Search" aria-label="Search this view"></label><span id="result-count" class="muted" aria-live="polite" aria-atomic="true"></span></div>
<div id="live-filters" aria-label="Filters"></div>
<div id="content" aria-busy="true"><p class="loading" role="status">Opening your space…</p></div></main></div>
<dialog id="detail" aria-label="Details"><div class="dialog-top"><span class="eyebrow" id="detail-kind"></span><button class="text-button" id="close-detail" aria-label="Close details">Close ×</button></div><div id="detail-content"></div></dialog>
<footer class="source-footer"><a href="/source">Source code · AGPLv3</a></footer>
</body></html>`;
}
