/**
 * SMTP credentials stay browser-owned while the rest of a form is patched.
 * Submission/reload generates new input ids, which must not inherit values.
 */
import { describe, expect, test } from 'vitest';
import { preserveSmtpCredentialValue } from '../smtp_credential_input';

/** Build the server's empty credential input without caching its DOM value. */
function input(name, generation = 1) {
  const el = document.createElement('input');
  el.id = `smtp-${name}-${generation}`;
  el.name = `smtp[${name}]`;
  el.type = name === 'password' ? 'password' : 'text';
  el.setAttribute('data-smtp-credential', '');
  el.setAttribute('value', '');
  return el;
}

describe('preserveSmtpCredentialValue', () => {
  test.each(['username', 'password'])('preserves %s when a public field is validated', name => {
    const current = input(name);
    const incoming = input(name);
    current.value = `unsaved-${name}`;
    // Typing changes the property, leaving identical empty HTML attributes.
    expect(current.isEqualNode(incoming)).toBe(true);

    preserveSmtpCredentialValue(current, incoming);

    expect(incoming.value).toBe(`unsaved-${name}`);
    expect(incoming.getAttribute('value')).toBe('');
  });

  test('preserves a cleared value instead of restoring previously typed credentials', () => {
    const current = input('password');
    current.value = 'previous-password';
    current.value = '';
    const incoming = input('password');

    preserveSmtpCredentialValue(current, incoming);

    expect(incoming.value).toBe('');
  });

  test('leaves validation, accessibility and disabled attributes under server control', () => {
    const current = input('password');
    current.value = 'unsaved-password';
    const incoming = input('password');
    incoming.required = true;
    incoming.disabled = true;
    incoming.setAttribute('aria-invalid', 'true');
    incoming.setAttribute('aria-describedby', 'password-error');

    preserveSmtpCredentialValue(current, incoming);

    expect(incoming.value).toBe('unsaved-password');
    expect(incoming.required).toBe(true);
    expect(incoming.disabled).toBe(true);
    expect(incoming.getAttribute('aria-invalid')).toBe('true');
    expect(incoming.getAttribute('aria-describedby')).toBe('password-error');
  });

  test.each(['username', 'password'])('does not copy %s into a new form generation', name => {
    const current = input(name);
    current.value = `unsaved-${name}`;
    const incoming = input(name, 2);

    preserveSmtpCredentialValue(current, incoming);

    expect(incoming.value).toBe('');
  });

  test.each(['current', 'incoming'])('ignores fields without the %s credential marker', side => {
    const current = input('username');
    current.value = 'unsaved-username';
    const incoming = input('username');
    (side === 'current' ? current : incoming).removeAttribute('data-smtp-credential');

    preserveSmtpCredentialValue(current, incoming);

    expect(incoming.value).toBe('');
  });

  test('does not preserve values on unkeyed inputs', () => {
    const current = input('password');
    current.removeAttribute('id');
    current.value = 'unsaved-password';
    const incoming = input('password');
    incoming.removeAttribute('id');

    preserveSmtpCredentialValue(current, incoming);

    expect(incoming.value).toBe('');
  });
});
