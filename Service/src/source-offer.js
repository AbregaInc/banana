// SPDX-License-Identifier: AGPL-3.0-only
// A release identifies its source explicitly; never imply that an unrelated main
// branch or the current developer checkout is the deployed version.
const revisionPattern = /^[a-f0-9]{40}$/;
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export function sourceInfo(config) {
  const revision = config.sourceRevision ?? '';
  if (!revisionPattern.test(revision)) return null;
  try {
    const url = new URL(config.sourceArchiveUrl);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) return null;
    // Support common archive layouts, including GitHub /archive/<sha>.tar.gz
    // and GitLab /-/archive/<sha>/project-<sha>.tar.gz. A configured mirror may
    // use either layout. It must serve corresponding source without login.
    if (!url.pathname.split('/').some(p => p === revision || p === `${revision}.tar.gz` || p === `${revision}.zip`)) return null;
    return { license: 'AGPL-3.0-only', revision, archive: url.href };
  } catch { return null; }
}

export function sourceRoutes(app, config) {
  const info = sourceInfo(config);
  app.use('*', async (c, next) => {
    await next();
    c.header('Link', '</source>; rel="describedby"', { append: true });
  });
  app.get('/v1/source', c => {
    c.header('Cache-Control', 'no-store');
    return info ? c.json(info) : c.json({ error: 'source_unavailable' }, 503);
  });
  app.get('/source', c => {
    c.header('Cache-Control', 'no-store');
    c.header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'");
    c.header('Referrer-Policy', 'no-referrer');
    c.header('X-Content-Type-Options', 'nosniff');
    const body = info
      ? `<h1>Source code</h1><p>This Banana service is licensed under the <a href="https://www.gnu.org/licenses/agpl-3.0.html">GNU AGPL, version 3</a>.</p><p><a href="${escape(info.archive)}">Download the source for this deployment</a></p><p>Revision <code>${escape(info.revision)}</code></p><p>The archive includes the service, required shared code, dependency configuration, build instructions and licence notices.</p>`
      : '<h1>Source code</h1><p>The source download is temporarily unavailable. Please contact <a href="mailto:support@abrega.com">support@abrega.com</a>.</p>';
    return c.html(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Banana · Source code</title><style>body{margin:0;background:#fbf6ea;color:#221d38;font:16px/1.7 ui-monospace,monospace}main{max-width:760px;margin:auto;padding:48px 24px}a{color:inherit;text-underline-offset:4px}code{overflow-wrap:anywhere}h1{line-height:1.2}</style></head><body><main><p>Banana</p>${body}</main></body></html>`, info ? 200 : 503);
  });
}
