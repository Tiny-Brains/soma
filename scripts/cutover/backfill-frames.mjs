// THE LAST FRAME OF A MATCH PLAYED BEFORE THE REDESIGN, for the cards that draw one. Run by
// backfill-frames.sh; reads match ids on stdin, one per line, and writes one NDJSON line per match:
// {"match_id", "turn", "frame"} -- or {"match_id", "skip": <why>} when it cannot.
//
// The frame is what a runner sends in `finish` since the redesign (kalam-match-run's `frame` task):
// `tb.ants.replay-decode` of the recorded replay at its last turn. It is decoded here by the viewer
// the web image ships -- the same component, and the new engine re-simulates every replay recorded on
// the old one to identical states (ants' tools/equivalence.py; the cutover rehearsal) -- so a
// backfilled frame and a frame a runner sent tomorrow cannot disagree.
//
//   node backfill-frames.mjs <viz dir holding engine.js> <soma base url> < ids
import { createInterface } from "node:readline";

const [vizDir, api] = process.argv.slice(2);
const { frameAt } = await import(vizDir.replace(/\/$/, "") + "/engine.js");
const MAX = 65536; // match_frames_frame_shape

async function json(url) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const r = await fetch(url);
    if (r.status === 429) { await new Promise((ok) => setTimeout(ok, 1000 * (attempt + 1))); continue; }
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json();
  }
  throw new Error("HTTP 429, repeatedly");
}

for await (const line of createInterface({ input: process.stdin })) {
  const id = line.trim();
  if (!id) continue;
  try {
    const m = await json(`${api}/v1/matches/${id}`);
    if (!m.replay_url) { console.log(JSON.stringify({ match_id: id, skip: "no replay" })); continue; }
    const replay = await json(m.replay_url);
    const turn = Number(replay.turns ?? 0);
    const frame = frameAt(replay, turn);
    const size = Buffer.byteLength(JSON.stringify(frame));
    console.log(JSON.stringify(size > MAX ? { match_id: id, skip: `frame is ${size} bytes` } : { match_id: id, turn, frame }));
  } catch (e) {
    console.log(JSON.stringify({ match_id: id, skip: String(e.message || e).slice(0, 200) }));
  }
}
