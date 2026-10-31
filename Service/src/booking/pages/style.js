// The booking pages' one stylesheet, inlined in every page (one round trip fewer on a first visit,
// as the landing page does). The landing page's tokens: cream, ink, banana, IBM Plex Mono, the
// yellow button with its hard shadow and its hover lift. Light only. Rows are 44 px; the grid's
// height is set from the count of the day it shows, so nothing moves as it fills. The day is picked
// on a month grid, one month at a time, on every width (Calendly's and Cal.com's layout, 30 Oct
// 2026); the times run two to a row on a phone, three from 768 px and four from 1024 px.
//
// The fallback faces carry Plex Mono's metrics (advance 600/1000, ascent 1025, descent 275) onto
// Menlo, Consolas and Courier-like fonts, so the swap to Plex doesn't move a line. Tile edges are
// --edge, 3.4:1 on the cream; the focus ring is ink.

export const CSS = `
@font-face{font-family:"IBM Plex Mono";font-weight:400;font-display:swap;src:url(/book/fonts/IBMPlexMono-400.woff2) format("woff2")}
@font-face{font-family:"IBM Plex Mono";font-weight:700;font-display:swap;src:url(/book/fonts/IBMPlexMono-700.woff2) format("woff2")}
@font-face{font-family:pfm;src:local("Menlo"),local("Menlo-Regular");size-adjust:99.67%;ascent-override:102.84%;descent-override:27.59%;line-gap-override:0%}
@font-face{font-family:pfw;src:local("Consolas");size-adjust:109.13%;ascent-override:93.92%;descent-override:25.2%;line-gap-override:0%}
@font-face{font-family:pfc;src:local("Courier New"),local("CourierNewPSMT"),local("Droid Sans Mono"),local("Roboto Mono"),local("Liberation Mono"),local("DejaVu Sans Mono");size-adjust:100%;ascent-override:102.5%;descent-override:27.5%;line-gap-override:0%}
:root{color-scheme:light;--cream:#fbf6ea;--paper:#fffdf7;--ink:#221d38;--dim:#635c7f;--line:#e6dccb;--edge:#8a8299;--banana:#ffd84a;--red:#b0263d;--f:"IBM Plex Mono",pfm,pfw,pfc,ui-monospace,monospace}
*,::before,::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;background:var(--cream)}
body{margin:0;background:var(--cream);color:var(--ink);font:15px/1.5 var(--f);-webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent}
button,input,textarea{font:inherit;color:inherit;margin:0}
button{touch-action:manipulation}
a{color:inherit;text-underline-offset:3px}
h1,h2,h3,p{margin:0}
[hidden]{display:none!important}
.rz [data-rl]{visibility:hidden}
:focus-visible{outline:3px solid var(--ink);outline-offset:2px}
.w{max-width:1000px;margin:0 auto;padding:16px 16px 8px}
h1{font:700 26px/1.15 var(--f);letter-spacing:-.02em;text-wrap:balance}
.meta{color:var(--dim);font-size:14px;margin-top:6px}
.bar{margin-top:12px;padding:10px 12px;border:2px solid var(--line);border-radius:4px;background:var(--paper);font-size:14px;line-height:1.7}
.lk{display:inline-flex;align-items:center;min-height:44px;padding:0 6px;border:0;background:none;font-weight:700;text-decoration:underline;text-underline-offset:3px;cursor:pointer}
.bar .lk{display:inline;min-height:0;padding:12px 4px;margin:-12px 0}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:10px;min-height:48px;padding:0 20px;font:700 16px/1.2 var(--f);text-decoration:none;text-align:center;background:var(--banana);color:var(--ink);border:2px solid var(--ink);border-radius:4px;box-shadow:3px 3px 0 var(--ink);cursor:pointer;transition:transform .08s,box-shadow .08s}
.btn:active{transform:translate(2px,2px);box-shadow:1px 1px 0 var(--ink)}
.btn.off{opacity:.45;box-shadow:none}
.soon{display:flex;width:100%;margin-top:16px;min-height:52px;justify-content:space-between}
.soon span{font-weight:400}
.host{font-size:14px;font-weight:700;color:var(--dim);margin-bottom:6px}
.cal{margin-top:20px}
.mh{display:flex;align-items:center;gap:6px;margin-bottom:8px}
.mh h3{flex:1;font:700 15px/1.4 var(--f);margin:0}
.mn{width:44px;height:44px;padding:0;border:2px solid var(--edge);border-radius:4px;background:var(--paper);font-size:22px;line-height:1;cursor:pointer;transition:transform .08s,box-shadow .08s}
.mn:disabled{opacity:.3;cursor:default}
.cg{display:grid;grid-template-columns:repeat(7,1fr);gap:4px}
.cg b{font-size:12px;font-weight:400;color:var(--dim);text-align:center;padding-bottom:2px}
.d{display:flex;align-items:center;justify-content:center;height:44px;padding:0;border:2px solid var(--edge);border-radius:4px;background:var(--paper);font-weight:700;font-size:15px;line-height:1;cursor:pointer;transition:transform .08s,box-shadow .08s}
.d[aria-pressed=true]{background:var(--banana);border-color:var(--ink)}
.d:disabled{background:none;border-color:transparent;color:#a9a2bb;cursor:default}
.row{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:0 12px;margin-top:8px;scroll-margin-top:12px}
h2{font:700 15px/1.4 var(--f)}
.zone{font-size:14px;color:var(--dim)}
.zone .lk{color:var(--ink);padding-inline:2px}
.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;align-content:start;min-height:calc(var(--r2,1)*56px - 8px)}
.t{height:48px;display:flex;align-items:center;justify-content:center;padding:0 4px;border:2px solid var(--edge);border-radius:4px;background:var(--paper);font-weight:700;font-size:15px;font-variant-numeric:tabular-nums;cursor:pointer;white-space:nowrap;transition:transform .08s,box-shadow .08s}
.t.on,.t.cur{background:var(--banana);border-color:var(--ink)}
.t.cur{cursor:default}
.t:active,.d:not(:disabled):active,.mn:not(:disabled):active{transform:translate(1px,1px);box-shadow:none}
@media (hover:hover){.t:not(.cur):hover,.d:not(:disabled):hover,.mn:not(:disabled):hover{border-color:var(--ink);transform:translate(-1px,-1px);box-shadow:2px 2px 0 var(--ink)}.btn:hover{transform:translate(-1px,-1px);box-shadow:4px 4px 0 var(--ink)}}
.none{color:var(--dim);padding:20px 0}
.narrow{max-width:560px}
.panel{margin-top:16px;padding:20px 16px;border:2px solid var(--ink);border-radius:6px;background:var(--paper);box-shadow:4px 4px 0 var(--ink)}
.types{list-style:none;margin:20px 0 12px;padding:0;display:grid;gap:12px}
.type{display:flex;align-items:center;justify-content:space-between;gap:12px;min-height:68px;padding:10px 16px;border:2px solid var(--ink);border-radius:4px;background:var(--paper);text-decoration:none;box-shadow:3px 3px 0 var(--ink);transition:transform .08s,box-shadow .08s}
@media (hover:hover){.type:hover{transform:translate(-1px,-1px);box-shadow:4px 4px 0 var(--ink)}}
.type>span:first-child{display:grid;gap:2px}
.type b{font-size:16px}
.type small{color:var(--dim);font-size:13px}
.type>span:last-child{font-size:26px;line-height:1}
.btn.ghost{background:none;box-shadow:none}
.more{margin-top:8px;font-size:14px}
#fc .lk{font-weight:400;padding-inline:0}
.sec{margin-top:28px;padding-top:4px;border-top:2px solid var(--line)}
.stack{display:grid;gap:12px;justify-items:start;margin-top:16px}
footer{display:flex;flex-wrap:wrap;gap:0 18px;align-items:center;justify-content:center;margin-top:8px;font-size:13px;color:var(--dim)}
.brand{display:inline-flex;align-items:center;gap:6px;min-height:44px;font-weight:700;color:var(--ink);text-decoration:none}
.brand svg{width:16px;height:16px}
footer .lk{font-weight:400;color:var(--dim)}
dialog{border:0;padding:0;margin:auto auto 0;width:100%;max-width:100%;max-height:92dvh;overflow:auto;background:var(--paper);color:var(--ink);border-radius:14px 14px 0 0;border-top:2px solid var(--ink)}
dialog::backdrop{background:rgba(34,29,56,.42)}
dialog[open]{animation:up .2s cubic-bezier(.2,.8,.2,1)}
@keyframes up{from{transform:translateY(100%)}}
.sh{position:relative;display:grid;gap:14px;padding:18px 16px calc(18px + env(safe-area-inset-bottom))}
.sh header{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}
.x{flex:none;width:44px;height:44px;margin:-10px -8px 0 0;border:0;background:none;font-size:26px;line-height:1;cursor:pointer}
.card>.x{position:absolute;right:8px;top:8px;margin:0}
label{display:grid;gap:4px;font-size:14px;font-weight:700}
input,textarea{width:100%;min-height:48px;padding:10px 12px;border:2px solid var(--ink);border-radius:4px;background:#fff;font-size:16px;font-weight:400}
input[type=search]::-webkit-search-cancel-button{-webkit-appearance:none;appearance:none}
textarea{min-height:96px;resize:vertical}
[aria-invalid=true]{border-color:var(--red)}
.err{color:var(--red);font-size:13px;font-weight:400}
.places{display:flex;flex-wrap:wrap;gap:8px;border:0;margin:0;padding:0;min-width:0}
.places legend{padding:0;margin-bottom:4px;font-size:14px;font-weight:700}
.pl{position:relative;display:block;font-weight:400}
.pl input{position:absolute;opacity:0;width:1px;height:1px;min-height:0}
.pl span{display:flex;align-items:center;min-height:44px;padding:0 14px;border:2px solid var(--edge);border-radius:4px;background:#fff}
.pl input:checked+span{background:var(--banana);border-color:var(--ink);font-weight:700}
.pl input:focus-visible+span{outline:3px solid var(--ink);outline-offset:2px}
.book{width:100%}
.card{justify-items:start;gap:10px}
.ck{width:44px;height:44px;padding:9px;background:var(--banana);border:2px solid var(--ink);border-radius:50%;fill:none;stroke:var(--ink);stroke-width:3;stroke-linecap:round;stroke-linejoin:round;stroke-dasharray:22;animation:draw .35s ease-out}
@keyframes draw{from{stroke-dashoffset:22}}
.card h2{font-size:22px;line-height:1.2}
.when{color:var(--dim);font-size:14px}
.when b{font-size:16px;color:var(--ink)}
.inv{color:var(--dim);font-size:14px}
.link{display:flex;flex-wrap:wrap;align-items:center;gap:0 8px}
.link a{overflow-wrap:anywhere}
.q{min-height:44px;padding:0 12px;border:2px solid var(--ink);border-radius:4px;background:none;font-weight:700;font-size:13px;cursor:pointer}
.acts{display:flex;flex-wrap:wrap;align-items:center;gap:8px 16px;margin-top:4px}
.acts .btn{font-size:15px;padding:0 14px}
.acts>a:not(.btn),.acts>span:not(.btn){display:inline-flex;align-items:center;min-height:44px}
.acts>span:not(.btn){color:var(--dim)}
.undo{position:relative;display:flex;align-items:center;gap:12px;width:100%;margin-top:6px;padding-top:14px;border-top:2px solid var(--line)}
.undo i{position:absolute;left:0;top:-2px;width:100%;height:2px;background:var(--ink);transform-origin:0 0;animation:bar 5s linear forwards}
@keyframes bar{to{transform:scaleX(0)}}
.near{grid-template-columns:1fr;min-height:0}
.zs{padding-bottom:0}
.zl{list-style:none;margin:0 -16px;padding:0;height:min(60dvh,520px);overflow:auto;overscroll-behavior:contain}
.zl button{display:flex;justify-content:space-between;align-items:center;gap:12px;width:100%;min-height:48px;padding:0 16px;border:0;border-bottom:1px solid var(--line);background:none;text-align:left;cursor:pointer}
.zl button[aria-current]{background:var(--banana)}
.zl small{color:var(--dim);font-size:13px;white-space:nowrap}
.zl .og{padding:14px 16px 4px;font-size:12px;font-weight:700;color:var(--dim)}
.zl .none{padding:16px}
.code{position:relative;width:min(100%,336px);height:60px;margin-top:20px}
.bx{display:none}
.js .bx{display:grid;grid-template-columns:repeat(6,1fr);gap:8px;height:100%;pointer-events:none}
.bx span{display:grid;place-items:center;border:2px solid var(--edge);border-radius:4px;background:#fff;font:700 24px/1 var(--f)}
.bx span.on{border-color:var(--ink)}
.js .code input{position:absolute;inset:0;height:100%;opacity:.01;color:transparent;caret-color:transparent;letter-spacing:1em}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
@media (min-width:768px){
.w{padding:28px 24px 16px}
h1{font-size:32px}
.grid{grid-template-columns:repeat(3,1fr);min-height:calc(var(--r,1)*56px - 8px)}
.cols{display:grid;grid-template-columns:300px minmax(0,1fr);gap:40px;align-items:start}
.cols .row{margin-top:0}
.cols .sec:first-child{margin-top:0;padding-top:0;border:0}
.panel{margin-top:20px}
dialog{margin:auto;max-width:440px;border:2px solid var(--ink);border-radius:6px;box-shadow:6px 6px 0 var(--ink)}
dialog[open]{animation:pop .15s ease-out}
@keyframes pop{from{opacity:0;transform:scale(.97)}}
.sh{padding:22px 22px 24px}
.zl{margin:0 -22px}
.zl button,.zl .og{padding-inline:22px}
}
@media (min-width:1024px){.cols{grid-template-columns:340px minmax(0,1fr);gap:56px}.grid{grid-template-columns:repeat(4,1fr);min-height:calc(var(--r4,1)*56px - 8px)}.near{grid-template-columns:1fr}}
@media (prefers-reduced-motion:reduce){*,::before,::after{animation:none!important;transition:none!important}}
`.trim().replace(/\n/g, "");
