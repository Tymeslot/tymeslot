/**
 * Cascade overlap layout for one day column of the calendar canvas.
 *
 * Ported from the approved sketch (spec, "Grid and density"):
 *  - events that start close together (about 25px apart) share the width;
 *  - an event that starts later overlays the earlier one with an indent, so
 *    the earlier title stays readable; the indent reuses the first depth no
 *    overlapping event holds, and never leaves less than MIN_EVENT_WIDTH;
 *  - a short event inside a long one overlays the long one's right half (on a
 *    narrow host, all but its left third) instead of halving it throughout;
 *  - touching events do not overlap;
 *  - when shared columns would fall below MIN_EVENT_WIDTH, the crowd folds
 *    into a "+N more" chip, each remaining column FOLD_COLUMN_WIDTH wide or
 *    more. Under about 94px only one, narrower column fits beside the chip;
 *    where even that one would be under MIN_EVENT_WIDTH, the chip shows alone
 *    (across the whole column, or at the right edge of an indented group).
 * Added to the sketch: the fold is decided per moment, not per group. An
 * event is hidden only if, at some point in its life, more events than there
 * are columns run at once and it ranks below them: one that needs attention
 * (sync pending or failed, or a request waiting for an answer; see
 * `segmentsForDay` in time.js) ranks first, then the longer one. Each chip covers
 * only the stretch where something is hidden, and a chip still hiding an
 * attention item is marked `warn`.
 *
 * Also added: an event takes the room its drawn box needs, not just its
 * minutes, so a 15-minute event whose box (and title line) runs past its end
 * shares the width with the event that starts there instead of lying under
 * it. And no visible event is ever narrower than MIN_EVENT_WIDTH (or the
 * column, if that is narrower): `layoutColumn` folds any event the cascade
 * would still squeeze below it into the chip, keeping attention items first.
 *
 * All inputs are plain data; text measurement is injected (`measureLines`),
 * so the module is testable without a canvas.
 */
export const MIN_EVENT_WIDTH = 56;
export const FOLD_COLUMN_WIDTH = 64;
export const CHIP_WIDTH = 30;
export const LINE_HEIGHT = 15;
export const PAD_TOP = 3;

const SHORT_EVENT = 30;
const MINUTES_PER_DAY = 1440;
const ceil15 = (minutes) => Math.ceil(minutes / 15) * 15;
// Overlap by the room each box takes on screen (`ve`, its visual end).
const overlaps = (a, b) => a.s < b.ve && a.ve > b.s;
const compareIds = (a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
// Stronger first: attention, then longer, then earlier, then by id.
const byStrength = (a, b) => Number(!!b.attention) - Number(!!a.attention) || b.e - b.s - (a.e - a.s) || a.s - b.s || compareIds(a, b);

/**
 * How many lines `text` wraps to in `width` px, by whole words. A title never
 * breaks inside a word: a word wider than the line takes a line of its own,
 * cut short with an ellipsis (render.js marks it, see `isLongWord`), so it
 * counts as one full line.
 */
export function countLines(text, width, measureWidth) {
  const room = Math.max(24, width);
  const space = measureWidth(" ");
  let lines = 1;
  let current = 0;

  for (const word of String(text ?? "").split(/\s+/).filter(Boolean)) {
    const w = Math.min(room, measureWidth(word));
    if (current && current + space + w > room) {
      lines += 1;
      current = w;
    } else {
      current += (current ? space : 0) + w;
    }
  }

  return lines;
}

/**
 * Whether a word is too wide for a line of `width` px and so must truncate on
 * its own line rather than wrap mid-word. A little slack covers the gap
 * between canvas measurement and the browser's layout; marking a word that
 * would just fit costs nothing, since it draws the same.
 */
export function isLongWord(word, width, measureWidth) {
  return measureWidth(word) > Math.max(24, width) - 2;
}

// MIN_EVENT_WIDTH, less the sub-pixel share a column split leaves over.
const READABLE = MIN_EVENT_WIDTH - 0.5;

// How many columns fit beside the chip once `width` folds: at least one, or
// none when even one would be narrower than MIN_EVENT_WIDTH and the chip
// shows alone.
const foldSlots = (width) =>
  width - CHIP_WIDTH < READABLE ? 0 : Math.max(1, Math.floor((width - CHIP_WIDTH) / FOLD_COLUMN_WIDTH));
const foldedWidth = (width) => (foldSlots(width) ? (width - CHIP_WIDTH) / foldSlots(width) : 0);

// Whether `width` split `n` ways folds: whenever a column would be narrower
// than MIN_EVENT_WIDTH.
const folds = (width, n) => n > 1 && width / n < READABLE;

// The width of one column of `width` split `n` ways, after any fold.
const columnWidth = (width, n) => (folds(width, n) ? foldedWidth(width) : width / n);

/**
 * Lays out one day's segments ({ id, s, e, title, attention }, minutes from
 * midnight). Returns events ({ id, s, e, level, left, width, z, nestIn }) and
 * chips ({ chip: true, ids, hidden, s, e, left, width, z, warn }), in px
 * across the column; `placeDay` adds the vertical pass. `minHeight` is the
 * shortest box `placeDay` draws; `hide` lists ids to fold into a chip whatever
 * the room (`layoutColumn` uses it to keep every event readable).
 */
export function layoutDay(segments, { colWidth, hourHeight, yOf, measureLines, minHeight = 20, hide = [] }) {
  // The minutes a box of `px` pixels (plus the 2px gap below it) spans.
  const minutesOf = (px) => ((px + 2) / hourHeight) * 60;
  const forced = new Set(hide);
  const segs = segments
    .map((segment) => ({ ...segment, ve: Math.max(segment.e, segment.s + minutesOf(minHeight)), drop: 0, forced: forced.has(segment.id) }))
    .sort((a, b) => a.s - b.s || b.e - b.s - (a.e - a.s) || compareIds(a, b));

  const startGap = Math.max(15, ceil15((22 / hourHeight) * 60));
  const indent = Math.max(12, Math.round(colWidth * 0.18));
  const placed = [];
  const groups = [];

  for (const g of segs) {
    const over = placed.filter((p) => overlaps(p, g));
    // Overlay only when the earlier event's title (up to two lines, in its
    // own column) fits above the later one; otherwise the two share columns.
    const close = over.filter(
      (p) =>
        g.s - p.s < startGap ||
        yOf(g.s) - yOf(p.s) - p.drop < 4 + LINE_HEIGHT * Math.min(2, measureLines(p.title, columnWidth(p.group.width, p.group.ends.length) - 14)),
    );
    const isShort = g.e - g.s <= SHORT_EVENT;
    const shortInLong = close.length > 0 && close.every((p) => p.e - p.s >= 90) && isShort;

    if (!close.length || shortInLong) {
      // Drawn above everything it overlaps, but indented only to the first
      // depth no overlapping event holds, so a chain reuses ended indents.
      const level = over.length ? Math.max(...over.map((p) => p.level)) + 1 : 0;
      let depth = 0;
      while (over.some((p) => p.depth === depth)) depth += 1;
      let left = Math.max(0, Math.min(depth * indent, Math.round(colWidth * 0.6), colWidth - MIN_EVENT_WIDTH));
      if (shortInLong) {
        // Nest in the topmost close event, the strongest of those at that
        // level, and overlay its right half (two thirds when it is narrow).
        const top = Math.max(...close.map((p) => p.level));
        const host = close.filter((p) => p.level === top).sort(byStrength)[0];
        const { left: hostLeft, width: hostWidth } = host.group;
        left = nestLeft(hostLeft, hostWidth);
        depth = host.depth + 1;
        g.nestIn = host.id;
      }
      const group = { left, width: colWidth - left, members: [], ends: [], nested: shortInLong };
      groups.push(group);
      g.level = level;
      g.depth = depth;
      join(group, g);
    } else {
      // A long event shares with an event of its own kind, never with a short
      // one nested inside a third, whose narrow group would fold it away.
      const own = isShort ? [] : close.filter((p) => !p.group.nested);
      const candidates = own.length ? own : close;
      const host = candidates[candidates.length - 1];
      g.level = host.level;
      g.depth = host.depth;
      if (host.nestIn) g.nestIn = host.nestIn;
      join(host.group, g);
    }

    if (g.nestIn) {
      // placeDay pushes a nested box below its host's first line.
      const host = placed.find((p) => p.id === g.nestIn);
      g.drop = Math.max(0, yOf(host.s) + host.drop + PAD_TOP + LINE_HEIGHT + 3 - yOf(g.s));
      g.ve = Math.max(g.ve, g.s + minutesOf(g.drop + minHeight));
    }
    placed.push(g);
  }

  const chipZ = 4 + Math.max(0, ...segs.map((g) => g.level));
  const seg = new Map(segs.map((g) => [g.id, g]));
  const out = [];
  for (const group of groups) {
    // A nested group overlays its host's drawn box, not the host's group,
    // which a later event may have split into columns.
    if (group.nested) placeNested(group, out, seg);
    out.push(...layoutGroup(group, chipZ));
  }

  // A nested event whose host folded behind a chip nests in a visible event
  // of the host's group that starts no later instead, or in none.
  for (const item of out) {
    if (item.chip || !item.nestIn || !seg.get(item.nestIn).hidden) continue;
    const other = seg.get(item.nestIn).group.members.find((o) => !o.hidden && o.id !== item.id && o.s <= item.s && overlaps(o, item));
    item.nestIn = other ? other.id : null;
  }

  return out;
}

// Places a nested group against its host's drawn box. A host folded behind
// its group's chip hands the nest to a visible event of that group that
// starts no later (placeDay drops a nested box below its host's top); failing
// one, the nested group ends at the chip's edge rather than under it.
function placeNested(group, out, seg) {
  const first = group.members[0];
  let host = seg.get(first.nestIn);
  const hostGroup = host.group;
  if (host.hidden) {
    host = hostGroup.members.find((o) => !o.hidden && o.s <= first.s && overlaps(o, first));
    for (const m of group.members) m.nestIn = host ? host.id : null;
  }

  const box = host && out.find((item) => !item.chip && item.id === host.id);
  if (box) {
    group.left = nestLeft(box.left, box.width);
    group.width = box.left + box.width - group.left;
  } else {
    const edge = hostGroup.left + hostGroup.width - CHIP_WIDTH;
    group.left = Math.max(hostGroup.left, Math.min(group.left, edge - MIN_EVENT_WIDTH));
    group.width = Math.max(0, edge - group.left);
  }
}

// Where a short event nested in a box at `left`, `width` wide starts: its right
// half, or its right two thirds when narrow, keeping MIN_EVENT_WIDTH if it can.
function nestLeft(left, width) {
  const start = left + (width < 140 ? width / 3 : width * 0.5);
  return Math.round(Math.max(left, Math.min(start, left + width - MIN_EVENT_WIDTH)));
}

function join(group, g) {
  const col = group.ends.findIndex((end) => end <= g.s);
  if (col < 0) group.ends.push(g.ve);
  else group.ends[col] = g.ve;
  group.members.push(g);
  g.group = group;
}

// Lays out each run of transitively overlapping members on its own, so one
// crowd's columns and fold do not outlive it.
function layoutGroup(group, chipZ) {
  return runsOf(group.members).flatMap((run) => layoutRun(group, run, chipZ));
}

function layoutRun(group, members, chipZ) {
  const n = assignSlots(members).length;
  // A member that must fold needs the chip, so its whole run folds.
  const folding = members.some((m) => m.forced) || folds(group.width, n);
  const slots = folding ? foldSlots(group.width) : n;
  const unit = folding ? foldedWidth(group.width) : group.width / n;
  const shown = folding ? chooseVisible(members.filter((m) => !m.forced), slots) : members;
  for (const m of members) m.hidden = !shown.includes(m);
  const visible = members.filter((m) => !m.hidden);
  assignSlots(visible);

  const out = [];
  for (const m of visible) {
    let span = 1;
    for (let k = m.slot + 1; k < slots; k += 1) {
      if (visible.some((o) => o !== m && o.slot === k && overlaps(o, m))) break;
      span += 1;
    }

    out.push({ id: m.id, s: m.s, e: m.e, level: m.level, left: group.left + m.slot * unit, width: span * unit, z: 3 + m.level, nestIn: m.nestIn ?? null });
  }

  // A chip alone takes the whole of a column's own group, but only the right
  // edge of an indented or nested group, clear of the event underneath.
  const whole = !slots && group.left === 0 && !group.nested;
  const chipWidth = whole ? group.width : Math.min(CHIP_WIDTH, group.width);
  for (const hidden of runsOf(members.filter((m) => m.hidden))) {
    const s = Math.min(...hidden.map((m) => m.s));
    const e = Math.max(...hidden.map((m) => m.e));
    const ve = Math.max(...hidden.map((m) => m.ve));
    out.push({
      chip: true,
      ids: members.filter((m) => m.s < ve && m.ve > s).map((m) => m.id),
      hidden: hidden.map((m) => m.id),
      s,
      e,
      left: group.left + group.width - chipWidth,
      width: chipWidth,
      z: chipZ,
      warn: hidden.some((m) => m.attention),
    });
  }

  return out;
}

// Gives each member (in start order) the lowest free slot; returns the slot
// ends, whose count is the most members that overlap at once.
function assignSlots(members) {
  const ends = [];
  for (const m of members) {
    let slot = ends.findIndex((end) => end <= m.s);
    if (slot < 0) slot = ends.push(m.ve) - 1;
    else ends[slot] = m.ve;
    m.slot = slot;
  }
  return ends;
}

// The members that stay visible with `slots` columns: strongest first, each
// kept unless `slots` stronger ones already run at some moment of its life.
function chooseVisible(members, slots) {
  const kept = [];
  for (const m of [...members].sort(byStrength)) {
    const moments = [m.s, ...kept.filter((o) => o.s > m.s && o.s < m.ve).map((o) => o.s)];
    const peak = Math.max(...moments.map((t) => kept.filter((o) => o.s <= t && o.ve > t).length));
    if (peak < slots) kept.push(m);
  }
  return members.filter((m) => kept.includes(m));
}

// Splits members (in start order) into runs that overlap transitively.
function runsOf(members) {
  const runs = [];
  let end = -Infinity;
  for (const m of members) {
    if (!runs.length || m.s >= end) {
      runs.push([m]);
      end = m.ve;
    } else {
      runs[runs.length - 1].push(m);
      end = Math.max(end, m.ve);
    }
  }
  return runs;
}

/**
 * The vertical pass: px top and height for each item, chips that touch merged
 * into one, nested short events pushed below their host's first line, and
 * each title clamped (`lineClamp`) so nothing drawn above an event covers its
 * title text, and any event whose title line runs into a chip stops at the
 * chip. `hideTime` drops the time line where the title needs the room;
 * `timeGap` moves a host's time line below the short event nested in it.
 */
export function placeDay(laid, { yOf, minHeight = 20 }) {
  const items = laid.map((item) => ({ ...item }));
  // Nothing hangs below the end of the day, however short it is.
  const dayEnd = yOf(MINUTES_PER_DAY);
  const clamp = (item) => {
    item.top = Math.min(item.top, dayEnd - item.height);
  };
  for (const item of items) {
    item.top = yOf(item.s);
    item.height = Math.max(minHeight, yOf(item.e) - item.top - 2);
    if (item.chip) item.height = Math.max(36, item.height);
    clamp(item);
  }

  const evs = items.filter((item) => !item.chip);
  const byId = new Map(evs.map((item) => [item.id, item]));
  const merged = [];

  for (const chip of items.filter((item) => item.chip).sort((a, b) => a.top - b.top)) {
    const last = merged[merged.length - 1];
    if (last && chip.top < last.top + last.height + 2) {
      last.ids = [...new Set([...last.ids, ...chip.ids])];
      last.hidden = [...new Set([...last.hidden, ...chip.hidden])];
      last.e = Math.max(last.e, chip.e);
      last.height = Math.max(last.top + last.height, chip.top + chip.height) - last.top;
      last.warn = last.warn || chip.warn;
    } else {
      merged.push(chip);
    }
  }

  for (const item of evs) {
    if (!item.nestIn) continue;
    const host = byId.get(item.nestIn);
    if (!host) continue;
    const minTop = host.top + PAD_TOP + LINE_HEIGHT + 3;
    if (item.top < minTop) {
      const bottom = item.top + item.height;
      item.top = minTop;
      item.height = Math.max(minHeight, bottom - item.top);
      clamp(item);
    }
  }

  // A chip draws above every event, so one whose title line runs into a
  // chip stops at the chip's edge instead of losing its end under it.
  for (const a of evs) {
    const lineEnd = a.top + Math.min(a.height, PAD_TOP + LINE_HEIGHT);
    for (const c of merged) {
      if (a.left < c.left && c.left < a.left + a.width && c.top < lineEnd && c.top + c.height > a.top) a.width = c.left - a.left;
    }
  }

  for (const a of evs) {
    if (a.height < 38) continue;
    const covers = [...evs, ...merged].filter(
      (b) =>
        b !== a &&
        (b.chip || b.z > a.z) &&
        b.left < a.left + a.width - 4 &&
        b.left + b.width > a.left + 4 &&
        b.top >= a.top - 1 &&
        b.top < a.top + a.height,
    );
    if (!covers.length) continue;

    const b = covers.reduce((x, y) => (y.top < x.top ? y : x));
    const free = b.top - a.top;
    a.lineClamp = Math.max(1, Math.min(4, Math.floor((free - PAD_TOP - 1) / LINE_HEIGHT)));
    const textEnd = PAD_TOP + a.lineClamp * LINE_HEIGHT + 1;

    if (b.nestIn === a.id && b.top + b.height + 16 < a.top + a.height) {
      a.timeGap = Math.max(0, b.top + b.height + 2 - a.top - textEnd);
    } else if (free < textEnd + 14) {
      a.hideTime = true;
    }
  }

  return [...evs, ...merged];
}

/**
 * layoutDay then placeDay, for one column, folding into the chip any event
 * that is still not readable as drawn (narrower than MIN_EVENT_WIDTH, as an
 * indented or nested event or one cut short at a chip can be, or with an
 * event or chip over its title line) until none is. An event that needs
 * attention is never the one folded while it can displace one that does not.
 */
export function layoutColumn(segments, opts) {
  const minHeight = opts.minHeight ?? 20;
  const floor = Math.min(READABLE, opts.colWidth - 0.5);
  const seg = new Map(segments.map((g) => [g.id, g]));
  const measureLines = memoised(opts.measureLines);
  const hide = [];
  let placed = [];

  // Each pass folds one more event, so a fold settles within segments.length
  // passes; the cap is a guard should a pass ever fold nothing new, drawing
  // the last pass rather than hanging the page.
  for (let pass = 0; pass <= segments.length; pass++) {
    placed = placeDay(layoutDay(segments, { ...opts, measureLines, minHeight, hide }), { yOf: opts.yOf, minHeight });
    const clashing = unreadable(placed, floor);
    if (!clashing.length) return placed;
    hide.push(foldVictim(clashing.map((id) => seg.get(id)), placed, seg).id);
  }
  return placed;
}

// Every pass measures the same titles at the same widths again: measure each
// (title, width) once per column.
function memoised(measureLines) {
  const lines = new Map();
  return (title, width) => {
    const key = `${width}\u0000${title}`;
    if (!lines.has(key)) lines.set(key, measureLines(title, width));
    return lines.get(key);
  };
}

// The ids of events not readable as drawn: too narrow, or with a chip or a
// later-drawn event across their first title line (both events count then).
function unreadable(placed, floor) {
  const ids = new Set();
  placed.forEach((a, i) => {
    if (a.chip) return;
    if (a.width < floor) ids.add(a.id);
    const lineEnd = a.top + Math.min(a.height, PAD_TOP + LINE_HEIGHT);
    placed.forEach((b, j) => {
      if (b === a || !(b.chip || b.z > a.z || (b.z === a.z && j > i))) return;
      const across = Math.min(a.left + a.width, b.left + b.width) - Math.max(a.left, b.left);
      const down = Math.min(lineEnd, b.top + b.height) - Math.max(a.top, b.top);
      if (across <= 4 || down <= 0.5) return;
      ids.add(a.id);
      if (!b.chip) ids.add(b.id);
    });
  });
  return [...ids];
}

// The event to fold among clashing ones: the weakest that does not need
// attention; failing that, the weakest event without attention drawn across
// the weakest clashing one; failing that, that one itself.
function foldVictim(clashing, placed, seg) {
  const weakest = (list) => [...list].sort(byStrength).at(-1);
  const plain = clashing.filter((g) => !g.attention);
  if (plain.length) return weakest(plain);

  const target = weakest(clashing);
  const box = placed.find((item) => item.id === target.id);
  const rivals = placed
    .filter((item) => !item.chip && item.id !== box.id && item.s < box.e && item.e > box.s)
    .filter((item) => item.left < box.left + box.width && item.left + item.width > box.left)
    .map((item) => seg.get(item.id))
    .filter((g) => !g.attention);
  return rivals.length ? weakest(rivals) : target;
}
