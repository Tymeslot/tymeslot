/**
 * Tests for the `ReminderCustomRow` hook (hooks/reminder_custom_row.js), which
 * adds a typed custom reminder when focus leaves the picker's custom row.
 */

import { describe, expect, test, afterEach, vi } from 'vitest';
import { ReminderCustomRow, shouldCommit } from '../hooks/reminder_custom_row';

function buildPicker(value = '3') {
  document.body.innerHTML = `
    <button data-discards-custom-reminder id="toggle">Cancel Custom</button>
    <div id="row" data-commit-event="commit_custom_reminder">
      <input name="reminder[value]" value="${value}" />
      <select name="reminder[unit]"><option value="hours" selected>Hours</option></select>
      <button id="add">Add</button>
    </div>
    <button id="elsewhere">Create</button>
  `;

  const row = document.getElementById('row');
  const hook = Object.create(ReminderCustomRow);
  hook.el = row;
  hook.pushEventTo = vi.fn();
  hook.mounted();
  return { row, hook };
}

function leave(row, relatedTarget) {
  row.querySelector('input').dispatchEvent(new FocusEvent('focusout', { bubbles: true, relatedTarget }));
}

afterEach(() => {
  document.body.innerHTML = '';
});

describe('shouldCommit', () => {
  test('commits a value when focus leaves for somewhere else', () => {
    const { row, hook } = buildPicker();
    expect(shouldCommit(row, document.getElementById('elsewhere'), '3')).toBe(true);
    hook.destroyed();
  });

  test('ignores focus moving within the row', () => {
    const { row, hook } = buildPicker();
    expect(shouldCommit(row, document.getElementById('add'), '3')).toBe(false);
    hook.destroyed();
  });

  test('ignores the Cancel Custom toggle, which discards the value', () => {
    const { row, hook } = buildPicker();
    expect(shouldCommit(row, document.getElementById('toggle'), '3')).toBe(false);
    hook.destroyed();
  });

  test('ignores an empty row', () => {
    const { row, hook } = buildPicker('');
    expect(shouldCommit(row, null, '  ')).toBe(false);
    hook.destroyed();
  });
});

describe('ReminderCustomRow', () => {
  test('pushes the row values when focus leaves it', () => {
    const { row, hook } = buildPicker();
    leave(row, document.getElementById('elsewhere'));

    expect(hook.pushEventTo).toHaveBeenCalledWith(row, 'commit_custom_reminder', {
      reminder: { value: '3', unit: 'hours' },
    });
    hook.destroyed();
  });

  // Safari focuses no clicked button, so the focusout carries no relatedTarget.
  test('judges by the pressed element when focusout names no target', () => {
    const { row, hook } = buildPicker();
    document.getElementById('add').dispatchEvent(new Event('pointerdown', { bubbles: true }));
    leave(row, null);

    expect(hook.pushEventTo).not.toHaveBeenCalled();
    hook.destroyed();
  });
});
