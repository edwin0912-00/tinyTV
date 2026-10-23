// Release ↔ context matching from kino.html, on real tracker names. Run: node app/tests/match.test.mjs (exit 1 on a failure).
// Owner 2026-10-23: E06 played for E18, and a release was called Ukrainian while its file had English only.
import fs from 'node:fs';
const html = fs.readFileSync(new URL('../remote/web/kino.html', import.meta.url), 'utf8');
const block = html.slice(html.indexOf('// MATCH-BEGIN'), html.indexOf('// MATCH-END'));
const tags = /const audioTags = [\s\S]*?return tags; };/.exec(html)[0];
const { epOf, epOk, ctxOk, audioTags } = new Function(block + '\n' + tags + '\nreturn { epOf, epOk, ctxOk, audioTags };')();

let fail = 0;
const eq = (name, got, want) => { const ok = JSON.stringify(got) === JSON.stringify(want); if (!ok) fail++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : `  got ${JSON.stringify(got)} want ${JSON.stringify(want)}`}`); };
const ep = (title, s, e) => epOk({ title }, s, e);
const ua = title => audioTags(title).some(([n]) => n === 'UA');

// Episode: the owner's case first.
eq('HHWEB S02E06 rejected for S2E18', ep('The Mentalist S02E06 2008 1080p NF WEB-DL DDP5 1 H 264-HHWEB', 2, 18), false);
eq('HHWEB S02E18 accepted', ep('The Mentalist S02E18 2008 1080p NF WEB-DL DDP5 1 H 264-HHWEB', 2, 18), true);
eq('file name S02E18 accepted', ep('The Mentalist S02E18 Aingavite Baa.mkv', 2, 18), true);
eq('s3e23 pack file rejected', ep('The.Mentalist.s03e23.WEB-DL.720p.UA.Eng.mkv', 2, 18), false);
eq('rutracker season 2, 1-23', ep('Менталист / The Mentalist / Сезон: 2 / Серии: 1-23 (23) (Крис Лонг, Дэвид Баррет) [2009, США, WEB-DL 720p]', 2, 18), true);
eq('rutracker season 2, 5-23 has 18', ep('Менталист / The Mentalist / Сезон: 2 / Серии: 5-23 (23) [2009, США, HDTV 720p]', 2, 18), true);
eq('rutracker season 2, 5-23 lacks 3', ep('Менталист / The Mentalist / Сезон: 2 / Серии: 5-23 (23) [2009, США, HDTV 720p]', 2, 3), false);
eq('season 1 pack rejected for S2', ep('Менталист / The Mentalist / Сезон: 1 / Серии: 1-23 (23) [2008, WEB-DL]', 2, 18), false);
eq('toloka seasons 1-7 = pack', ep('Менталіст (Сезони 1-7) / The Mentalist (Seasons 1-7) (2008-2015) BDRip/WEB-DL 720p/1080p Ukr/Eng', 2, 18), true);
eq('kinozal 1-7 сезоны = pack', ep('Менталист (1-7 сезоны: 1-151 серии из 151) / The Mentalist / 2008-2015 / ДБ (ТВ3) / WEB-DL (720p)', 2, 18), true);
eq('Season 2 Complete = pack', ep('The Mentalist Season 2 S02 720p WEB-DL x265 HEVC Complete', 2, 18), true);
eq('S02E01-E10 lacks 18', ep('The Mentalist S02E01-E10 1080p', 2, 18), false);
eq('3x18 rejected', ep('Mentalist 3x18', 2, 18), false);
eq('2x18 accepted', ep('Mentalist 2x18 720p', 2, 18), true);
eq('«2 сезон 18 серія»', ep('Менталіст 2 сезон 18 серія', 2, 18), true);
eq('«Сезон 2 Серія 17» rejected', ep('Менталіст Сезон 2 Серія 17', 2, 18), false);
eq('«18 серия», no season', ep('Менталист 18 серия', 2, 18), true);
eq('E18 inside a season folder', ep('The Mentalist/Season 2/E18.mkv', 2, 18), true);
eq('S01 pack rejected for S2', ep('The Mentalist S01 720p WEB-DL x264', 2, 18), false);
eq('S02 pack accepted', ep('The Mentalist S02 1080p WEB-DL', 2, 18), true);
eq('S01-S07 = all seasons', ep('The Mentalist S01-S07 Complete 1080p', 2, 18), true);
eq('whole series, no season info', ep('The Mentalist 2008 1080p WEB-DL', 2, 18), true);
eq('epOf S02E18', epOf('The.Mentalist.S02E18.720p'), { s: 2, a: 18, b: 18 });

// Title and year context.
const law = ['Лоуренс Аравийский', 'Lawrence of Arabia', 'Лоуренс Аравійський'];
eq('MobLand (actor Лоуренс Гоф) rejected', ctxOk({ title: 'Гангстерленд / MobLand / S1E1-10 of 10 (Энтони Бирн, Лоуренс Гоф, Гай Ричи) [2025, США]' }, law, 1962, false), false);
eq('Lawrence rutracker accepted', ctxOk({ title: 'Лоуренс Аравийский / Lawrence of Arabia (Дэвид Лин / David Lean) [1962, Великобритания, драма]' }, law, 1962, false), true);
eq('YTS English name accepted', ctxOk({ title: 'Lawrence Of Arabia (1962) [2160p] [4K] [BluRay] [5.1] [YTS.MX]' }, law, 1962, false), true);
eq('wrong year rejected', ctxOk({ title: 'Lawrence of Arabia (2026) parody WEBRip' }, law, 1962, false), false);
eq('series ignores year', ctxOk({ title: 'The Mentalist S02E18 2008 1080p NF WEB-DL' }, ['Менталист', 'The Mentalist'], 2008, true), true);
eq('other series rejected', ctxOk({ title: 'Mentalist Mind Tricks S02E18' }, ['Менталист', 'The Mentalist'], 2008, true), false);

// UA comes from the release itself only.
eq('HHWEB E06 is not UA', ua('The Mentalist S02E06 2008 1080p NF WEB-DL DDP5 1 H 264-HHWEB'), false);
eq('toloka Ukr/Eng is UA', ua('Менталіст (Сезони 1-7) / The Mentalist (Seasons 1-7) (2008-2015) BDRip/WEB-DL 720p/1080p Ukr/Eng'), true);
eq('file .UA.Eng is UA', ua('The.Mentalist.s03e23.WEB-DL.720p.UA.Eng.mkv'), true);

console.log(fail ? `\n${fail} failed` : '\nall passed'); process.exit(fail ? 1 : 0);
