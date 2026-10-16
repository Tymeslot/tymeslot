/**
 * Cascade overlap layout for one day column of the calendar canvas.
 *
 * Ported from the approved sketch (spec, "Grid and density"):
 *  - events that start close together (about 25px apart) share the width;
 *  - an event that starts later overlays the earlier one with an indent, so
 *    the earlier title stays readable;
 *  - a short event inside a long one overlays the long one's right half (on a
 *    narrow host, all but its left third) instead of halving it throughout;
 *  - touching events do not overlap;
 *  - when shared columns would fall below MIN_EVENT_WIDTH, the crowd folds
 *    into a "+N more" chip, each remaining column FOLD_COLUMN_WIDTH wide or
 *    more. A column too narrow for even one such column beside the chip
 *    (under about 94px) still keeps one, narrower column.
 * Added to the sketch: the fold is decided per moment, not per group. An
 * event is hidden only if, at some point in its life, more events than there
 * are columns run at once and it ranks below them: one that needs attention
 * (sync pending or failed) ranks first, then the longer one. Each chip covers
 * only the stretch where something is hidden, and a chip still hiding an
 * attention item is marked `warn`.
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
const overlaps = (a, b) => a.s < b.e && a.e > b.s;
const compareIds = (a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
// Stronger first: attention, then longer, then earlier, then by id.
const byStrength = (a, b) => Number(!!b.attention) - Number(!!a.attention) || b.e - b.s - (a.e - a.s) || a.s - b.s || compareIds(a, b);

/** How many lines `text` wraps to in `width` px, by whole words. */
export function countLines(text, width, measureWidth) {
  const room = Math.max(24, width);
  const space = measureWidth(" ");
  let lines = 1;
  let current = 0;

  for (const word of String(text ?? "").split(/\s+/).filter(Boolean)) {
    const w = measureWidth(word);
    if (current && current + space + w > room) {
      lines += 1;
      current = w;
    } else {
      current += (current ? space : 0) + w;
    }
    while (current > room) {
      lines += 1;
      current -= room;
    }
  }

  return lines;
}

// How many columns fit beside the chip once `width` folds: at least one.
const foldSlots = (width) => Math.max(1, Math.floor((width - CHIP_WIDTH) / FOLD_COLUMN_WIDTH));

// The width of one column of `width` split `n` ways, after any fold.
function columnWidth(width, n) {
  if (n > 1 && width / n < MIN_EVENT_WIDTH) return (width - CHIP_WIDTH) / foldSlots(width);
  return width / n;
}

/**
 * Lays out one day's segments ({ id, s, e, title, attention }, minutes from
 * midnight). Returns events ({ id, s, e, level, left, width, z, nestIn }) and
 * chips ({ chip: true, ids, hidden, s, e, left, width, z, warn }), in px
 * across the column; `placeDay` adds the vertical pass.
 */
export function layoutDay(segments, { colWidth, hourHeight, yOf, measureLines }) {
  const segs = segments.map((segment) => ({ ...segment })).sort((a, b) => a.s - b.s || b.e - b.s - (a.e - a.s) || compareIds(a, b));

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
        yOf(g.s) - yOf(p.s) < 4 + LINE_HEIGHT * Math.min(2, measureLines(p.title, columnWidth(p.group.width, p.group.ends.length) - 14)),
    );
    const isShort = g.e - g.s <= SHORT_EVENT;
    const shortInLong = close.length > 0 && close.every((p) => p.e - p.s >= 90) && isShort;

    if (!close.length || shortInLong) {
      const level = over.length ? Math.max(...over.map((p) => p.level)) + 1 : 0;
      let left = Math.min(level * indent, Math.round(colWidth * 0.6));
      if (shortInLong) {
        // Nest in the topmost close event, the strongest of those at that
        // level, and overlay its right half (two thirds when it is narrow).
        const top = Math.max(...close.map((p) => p.level));
        const host = close.filter((p) => p.level === top).sort(byStrength)[0];
        const { left: hostLeft, width: hostWidth } = host.group;
        left = Math.round(hostLeft + (hostWidth < 140 ? hostWidth / 3 : hostWidth * 0.5));
        g.nestIn = host.id;
      }
      const group = { left, width: colWidth - left, members: [], ends: [], nested: shortInLong };
      groups.push(group);
      g.level = level;
      join(group, g);
    } else {
      // A long event shares with an event of its own kind, never with a short
      // one nested inside a third, whose narrow group would fold it away.
      const own = isShort ? [] : close.filter((p) => !p.group.nested);
      const candidates = own.length ? own : close;
      const host = candidates[candidates.length - 1];
      g.level = host.level;
      if (host.nestIn) g.nestIn = host.nestIn;
      join(host.group, g);
    }

    placed.push(g);
  }

  const chipZ = 4 + Math.max(0, ...segs.map((g) => g.level));
  const out = groups.flatMap((group) => layoutGroup(group, chipZ));

  // A nested event whose host folded behind a chip nests in a visible event
  // of the host's group instead, or in none.
  const seg = new Map(segs.map((g) => [g.id, g]));
  for (const item of out) {
    if (item.chip || !item.nestIn || !seg.get(item.nestIn).hidden) continue;
    const other = seg.get(item.nestIn).group.members.find((o) => !o.hidden && o.id !== item.id && overlaps(o, item));
    item.nestIn = other ? other.id : null;
  }

  return out;
}

function join(group, g) {
  const col = group.ends.findIndex((end) => end <= g.s);
  if (col < 0) group.ends.push(g.e);
  else group.ends[col] = g.e;
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
  const folding = n > 1 && group.width / n < MIN_EVENT_WIDTH;
  const slots = folding ? foldSlots(group.width) : n;
  const unit = columnWidth(group.width, n);
  const shown = folding ? chooseVisible(members, slots) : members;
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

  for (const hidden of runsOf(members.filter((m) => m.hidden))) {
    const s = Math.min(...hidden.map((m) => m.s));
    const e = Math.max(...hidden.map((m) => m.e));
    out.push({
      chip: true,
      ids: members.filter((m) => m.s < e && m.e > s).map((m) => m.id),
      hidden: hidden.map((m) => m.id),
      s,
      e,
      left: group.left + group.width - CHIP_WIDTH,
      width: CHIP_WIDTH,
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
    if (slot < 0) slot = ends.push(m.e) - 1;
    else ends[slot] = m.e;
    m.slot = slot;
  }
  return ends;
}

// The members that stay visible with `slots` columns: strongest first, each
// kept unless `slots` stronger ones already run at some moment of its life.
function chooseVisible(members, slots) {
  const kept = [];
  for (const m of [...members].sort(byStrength)) {
    const moments = [m.s, ...kept.filter((o) => o.s > m.s && o.s < m.e).map((o) => o.s)];
    const peak = Math.max(...moments.map((t) => kept.filter((o) => o.s <= t && o.e > t).length));
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
      end = m.e;
    } else {
      runs[runs.length - 1].push(m);
      end = Math.max(end, m.e);
    }
  }
  return runs;
}

/**
 * The vertical pass: px top and height for each item, chips that touch merged
 * into one, nested short events pushed below their host's first line, and
 * each title clamped (`lineClamp`) so nothing drawn above an event covers its
 * title text. `hideTime` drops the time line where the title needs the room;
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

/** layoutDay then placeDay, for one column. */
export function layoutColumn(segments, opts) {
  return placeDay(layoutDay(segments, opts), { yOf: opts.yOf, minHeight: opts.minHeight ?? 20 });
}
