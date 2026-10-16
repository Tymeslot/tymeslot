/**
 * Cascade overlap layout for one day column of the calendar canvas.
 *
 * Ported from the approved sketch (spec, "Grid and density"):
 *  - events that start close together (about 25px apart) share the width;
 *  - an event that starts later overlays the earlier one with an indent, so
 *    the earlier title stays readable;
 *  - a short event inside a long one overlays the long one's right half (on a
 *    narrow column, all but its left third) instead of halving it throughout;
 *  - touching events do not overlap;
 *  - when shared columns would fall below MIN_EVENT_WIDTH, the extra columns
 *    fold into a "+N more" chip, each remaining column at least
 *    FOLD_COLUMN_WIDTH wide.
 * Added to the sketch: a column holding an event that needs attention (sync
 * pending or failed) is kept visible ahead of the others, and a chip that
 * still has to hide one is marked `warn`.
 *
 * All inputs are plain data; text measurement is injected (`measureLines`),
 * so the module is testable without a canvas.
 */
export const MIN_EVENT_WIDTH = 56;
export const FOLD_COLUMN_WIDTH = 64;
export const CHIP_WIDTH = 30;
export const LINE_HEIGHT = 15;
export const PAD_TOP = 3;

const ceil15 = (minutes) => Math.ceil(minutes / 15) * 15;

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

/**
 * Lays out one day's segments ({ id, s, e, title, attention }, minutes from
 * midnight). Returns events ({ id, s, e, level, left, width, z, nestIn }) and
 * chips ({ chip: true, ids, hidden, s, e, left, width, z, warn }), in px
 * across the column; `placeDay` adds the vertical pass.
 */
export function layoutDay(segments, { colWidth, hourHeight, yOf, measureLines }) {
  const segs = segments
    .map((segment) => ({ ...segment }))
    .sort((a, b) => a.s - b.s || b.e - b.s - (a.e - a.s) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  const startGap = Math.max(15, ceil15((22 / hourHeight) * 60));
  const indent = Math.max(12, Math.round(colWidth * 0.18));
  const placed = [];
  const groups = [];

  for (const g of segs) {
    const over = placed.filter((p) => p.s < g.e && p.e > g.s);
    // Overlay only when the earlier event's title (up to two lines) fits above
    // the later one; otherwise the two share columns.
    const close = over.filter(
      (p) =>
        g.s - p.s < startGap ||
        yOf(g.s) - yOf(p.s) < 4 + LINE_HEIGHT * Math.min(2, measureLines(p.title, p.group.width - CHIP_WIDTH - 14)),
    );
    const shortInLong = close.length > 0 && close.every((p) => p.e - p.s >= 90) && g.e - g.s <= 30;

    if (!close.length || shortInLong) {
      const level = over.length ? Math.max(...over.map((p) => p.level)) + 1 : 0;
      const left = shortInLong
        ? Math.round(colWidth < 140 ? colWidth / 3 : colWidth * 0.5)
        : Math.min(level * indent, Math.round(colWidth * 0.6));
      const group = { left, width: colWidth - left, members: [g] };
      groups.push(group);
      g.level = level;
      g.group = group;
      if (shortInLong) g.nestIn = close[close.length - 1].id;
    } else {
      const host = close[close.length - 1];
      host.group.members.push(g);
      g.level = host.level;
      g.group = host.group;
    }

    placed.push(g);
  }

  return groups.flatMap((group) => layoutGroup(group));
}

function layoutGroup(group) {
  const ends = [];
  for (const m of group.members) {
    let col = ends.findIndex((end) => end <= m.s);
    if (col < 0) {
      col = ends.length;
      ends.push(m.e);
    } else {
      ends[col] = m.e;
    }
    m.col = col;
  }

  const n = ends.length;
  const folding = n > 1 && group.width / n < MIN_EVENT_WIDTH;
  const slots = folding ? Math.max(1, Math.floor((group.width - CHIP_WIDTH) / FOLD_COLUMN_WIDTH)) : n;
  const visible = chooseColumns(group.members, n, slots);
  const slotOf = new Map(visible.map((col, slot) => [col, slot]));
  const unit = visible.length < n ? (group.width - CHIP_WIDTH) / visible.length : group.width / n;
  const out = [];
  const hidden = [];

  for (const m of group.members) {
    if (!slotOf.has(m.col)) {
      hidden.push(m);
      continue;
    }

    const slot = slotOf.get(m.col);
    let span = 1;
    for (let k = slot + 1; k < visible.length; k += 1) {
      const col = visible[k];
      if (group.members.some((o) => o !== m && o.col === col && o.s < m.e && o.e > m.s)) break;
      span += 1;
    }

    out.push({ id: m.id, s: m.s, e: m.e, level: m.level, left: group.left + slot * unit, width: span * unit, z: 3 + m.level, nestIn: m.nestIn ?? null });
  }

  if (hidden.length) {
    out.push({
      chip: true,
      ids: group.members.map((m) => m.id),
      hidden: hidden.map((m) => m.id),
      s: Math.min(...hidden.map((m) => m.s)),
      e: Math.max(...hidden.map((m) => m.e)),
      left: group.left + group.width - CHIP_WIDTH,
      width: CHIP_WIDTH,
      z: 14,
      warn: hidden.some((m) => m.attention),
    });
  }

  return out;
}

// The columns that stay visible: those holding an attention item first, then
// the rest in order, as many as there are slots, returned in column order.
function chooseColumns(members, n, slots) {
  const all = Array.from({ length: n }, (_, col) => col);
  if (slots >= n) return all;

  const urgent = all.filter((col) => members.some((m) => m.col === col && m.attention));
  const rest = all.filter((col) => !urgent.includes(col));

  return [...urgent, ...rest].slice(0, slots).sort((a, b) => a - b);
}
