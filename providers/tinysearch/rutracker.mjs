// RuTracker through the owner's logged-in Chrome on core host (DevTools port 18850), every forum section.
// No Cloudflare bypass: the request runs inside the owner's own open rutracker.org tab.
//   node rutracker.mjs search "<query>"   -> JSON rows {topic, title, forum, bytes, seeds, peers}
//   node rutracker.mjs magnet <topic id>  -> JSON {magnet}
const [mode, arg] = process.argv.slice(2), PORT = 18850;
const tabs = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
let tab = tabs.find(t => t.type === 'page' && t.url.startsWith('https://rutracker.org/'));
if (!tab) tab = await (await fetch(`http://127.0.0.1:${PORT}/json/new?https://rutracker.org/forum/index.php`, {method: 'PUT'})).json();

const js = mode === 'magnet' ? `(async () => {
  const r = await fetch('/forum/viewtopic.php?t=' + ${JSON.stringify(String(arg))});
  const d = new DOMParser().parseFromString(new TextDecoder('windows-1251').decode(await r.arrayBuffer()), 'text/html');
  const a = d.querySelector('a.magnet-link, a[href^="magnet:"]'); return {magnet: a ? a.getAttribute('href') : ''}; })()`
  : `(async () => {
  const r = await fetch('/forum/tracker.php?o=10&s=2&nm=' + encodeURIComponent(${JSON.stringify(arg || '')}));
  const d = new DOMParser().parseFromString(new TextDecoder('windows-1251').decode(await r.arrayBuffer()), 'text/html');
  if (!d.querySelector('#logged-in-username')) return {error: 'RuTracker: не залогінено в Chrome на tinyTV Core'};
  return [...d.querySelectorAll('tr.tCenter.hl-tr')].map(tr => { const a = tr.querySelector('a.tLink') || {};
    return {topic: (a.dataset || {}).topic_id || '', title: (a.textContent || '').trim(),
            forum: ((tr.querySelector('.f-name a, a.gen.f') || {}).textContent || '').trim(),
            bytes: +((tr.querySelector('td.tor-size') || {}).dataset || {}).ts_text || 0,
            seeds: +((tr.querySelector('b.seedmed') || {}).textContent || 0),
            peers: +((tr.querySelector('.leechmed') || {}).textContent || 0)}; }).filter(x => x.topic); })()`;

const ws = new WebSocket(tab.webSocketDebuggerUrl);
const out = await new Promise((ok, bad) => {
  const t = setTimeout(() => bad(new Error('RuTracker: Chrome не відповів за 20 с')), 20000);
  ws.onopen = () => ws.send(JSON.stringify({id: 1, method: 'Runtime.evaluate', params: {expression: js, awaitPromise: true, returnByValue: true}}));
  ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id !== 1) return; clearTimeout(t);
    d.result?.exceptionDetails ? bad(new Error(d.result.exceptionDetails.text)) : ok(d.result?.result?.value); };
  ws.onerror = () => bad(new Error('RuTracker: немає звʼязку з Chrome (порт 18850)'));
});
ws.close();
process.stdout.write(JSON.stringify(out ?? null));
