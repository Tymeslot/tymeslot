-- migration_dirty_seed.sql
--
-- Adversarial data for migration testing. This file is loaded before running
-- pending migrations to verify they handle real-world data shapes.
--
-- MAINTENANCE RULES:
-- 1. When a migration bug is found in production, add the offending data
--    pattern here as a regression case.
-- 2. When a migration adds a NOT NULL column to an existing table, update
--    the INSERTs here to include that column (with a valid value).
-- 3. Every INSERT must use explicit column lists — never INSERT INTO t VALUES.
-- 4. Comments explain WHY each row is adversarial, not what it contains.
-- 5. When the migration a row was written for drops out of the tested window,
--    delete the row. The window slides (the test takes the last N migrations)
--    and this file is loaded *after* the database has already been migrated up
--    to just before that window, so a row targeting an older migration cannot
--    exercise it any more — and the schema may by then refuse the row outright,
--    which fails the seed rather than the migration under test.
--
-- Tables seeded: users, profiles, user_sessions, calendar_integrations,
--                video_integrations, connect_accounts, payment_transactions,
--                booking_payments, meetings

-- ============================================================================
-- USERS
-- ============================================================================

-- Standard user with password auth
INSERT INTO users (email, password_hash, verified_at, inserted_at, updated_at)
VALUES ('seed-user-1@example.com', '$2b$12$K4fE6xkGz0qYkN2wQpYDOeG0G0G0G0G0G0G0G0G0G0G0G0G0G0', NOW(), NOW(), NOW());

-- OAuth user with no password (password_hash is NULL)
INSERT INTO users (email, provider, provider_uid, verified_at, inserted_at, updated_at)
VALUES ('seed-user-2@example.com', 'google', 'google-uid-123', NOW(), NOW(), NOW());

-- Unverified user (verified_at is NULL)
INSERT INTO users (email, password_hash, inserted_at, updated_at)
VALUES ('seed-user-3@example.com', '$2b$12$K4fE6xkGz0qYkN2wQpYDOeG0G0G0G0G0G0G0G0G0G0G0G0G0G0', NOW(), NOW());

-- ============================================================================
-- PROFILES
-- ============================================================================

-- Standard profile for user 1
INSERT INTO profiles (user_id, timezone, buffer_minutes, advance_booking_days, min_advance_hours, inserted_at, updated_at)
SELECT id, 'Europe/Tallinn', 15, 90, 3, NOW(), NOW() FROM users WHERE email = 'seed-user-1@example.com';

-- Profile with NULL optional fields (username, primary_calendar_integration_id)
INSERT INTO profiles (user_id, timezone, buffer_minutes, advance_booking_days, min_advance_hours, inserted_at, updated_at)
SELECT id, 'UTC', 0, 30, 0, NOW(), NOW() FROM users WHERE email = 'seed-user-2@example.com';

-- ============================================================================
-- USER SESSIONS
-- ============================================================================
--
-- Present before 20260702214204_hash_user_session_tokens — exercises the
-- plaintext-token backfill into token_hash (and the resulting unique index)
-- against pre-existing rows, not an empty table.

-- Standard active session for user 1.
INSERT INTO user_sessions (user_id, token, expires_at, inserted_at, updated_at)
SELECT id, 'seed-session-token-alpha', NOW() + INTERVAL '24 hours', NOW(), NOW()
FROM users WHERE email = 'seed-user-1@example.com';

-- A second, distinct session for the same user (same user_id, distinct token) —
-- exercises the per-row backfill rather than a single-row happy path.
INSERT INTO user_sessions (user_id, token, expires_at, inserted_at, updated_at)
SELECT id, 'seed-session-token-beta', NOW() + INTERVAL '24 hours', NOW(), NOW()
FROM users WHERE email = 'seed-user-1@example.com';

-- ============================================================================
-- CALENDAR INTEGRATIONS
-- ============================================================================

-- Active CalDAV integration for user 1.
--
-- This used to be a pair of duplicate active rows, kept as a regression case
-- for 20260323000001, which replaced the old uniqueness rule with the partial
-- index unique_active_calendar_null_account_per_user. That migration is long
-- out of the tested window, so by the time this file is loaded the index
-- already exists and rejects the duplicate outright (see maintenance rule 5).
INSERT INTO calendar_integrations (user_id, provider, base_url, name, is_active, verify_ssl, calendar_paths, calendar_list, inserted_at, updated_at)
SELECT id, 'caldav', 'https://dav.example.com', 'CalDAV Server 1', true, true, '{}', ARRAY[]::jsonb[], NOW(), NOW()
FROM users WHERE email = 'seed-user-1@example.com';

-- Different provider, same user (should not collide with the CalDAV rows)
INSERT INTO calendar_integrations (user_id, provider, base_url, name, is_active, verify_ssl, calendar_paths, calendar_list, inserted_at, updated_at)
SELECT id, 'nextcloud', 'https://cloud.example.com/remote.php/dav', 'Nextcloud', true, true, '{}', ARRAY[]::jsonb[], NOW(), NOW()
FROM users WHERE email = 'seed-user-1@example.com';

-- Inactive integration (should not interfere with active-only constraints)
INSERT INTO calendar_integrations (user_id, provider, base_url, name, is_active, verify_ssl, calendar_paths, calendar_list, inserted_at, updated_at)
SELECT id, 'caldav', 'https://old.example.com', 'Deactivated', false, true, '{}', ARRAY[]::jsonb[], NOW(), NOW()
FROM users WHERE email = 'seed-user-1@example.com';

-- Second user with a single integration (baseline — should never cause issues)
INSERT INTO calendar_integrations (user_id, provider, base_url, name, is_active, verify_ssl, calendar_paths, calendar_list, inserted_at, updated_at)
SELECT id, 'radicale', 'https://radicale.example.com', 'Radicale', true, true, '{}', ARRAY[]::jsonb[], NOW(), NOW()
FROM users WHERE email = 'seed-user-2@example.com';

-- ============================================================================
-- VIDEO INTEGRATIONS
-- ============================================================================

-- Active MiroTalk integration for user 1.
--
-- The duplicate-provider twin this row used to have was the regression case
-- for 20260317000003 / 20260323000001, which added
-- unique_active_video_null_account_per_user. Both are out of the tested window
-- now, so the index exists before this file is loaded and rejects the twin
-- (see maintenance rule 5).
INSERT INTO video_integrations (user_id, provider, base_url, name, is_active, settings, inserted_at, updated_at)
SELECT id, 'mirotalk', 'https://meet1.example.com', 'MiroTalk 1', true, '{}'::jsonb, NOW(), NOW()
FROM users WHERE email = 'seed-user-1@example.com';

-- Custom video integration with a URL (different provider, same user)
INSERT INTO video_integrations (user_id, provider, custom_meeting_url, name, is_active, settings, inserted_at, updated_at)
SELECT id, 'custom', 'https://zoom.us/j/123456', 'Custom Zoom', true, '{}'::jsonb, NOW(), NOW()
FROM users WHERE email = 'seed-user-1@example.com';

-- Inactive video integration
INSERT INTO video_integrations (user_id, provider, base_url, name, is_active, settings, inserted_at, updated_at)
SELECT id, 'mirotalk', 'https://old-meet.example.com', 'Old MiroTalk', false, '{}'::jsonb, NOW(), NOW()
FROM users WHERE email = 'seed-user-2@example.com';

-- ============================================================================
-- CALENDAR EVENTS (legacy shape) — REMOVED
-- ============================================================================
--
-- This section held six rows in the legacy `calendar_events` table, written as
-- regression cases for 20260408110831_recreate_provider_calendar_events (which
-- renames the table to `provider_calendar_events` and adds four NOT NULL
-- columns) and 20260415185057_add_sync_state_to_provider_calendar_events.
--
-- Both migrations are long out of the tested window. This file is loaded after
-- the database has been migrated up to just before that window, so by then the
-- rename has already happened, `calendar_events` does not exist, and every one
-- of those INSERTs fails with undefined_table. They could not exercise those
-- migrations either way (see maintenance rule 5), so they are gone.
--
-- If a future migration touches `provider_calendar_events`, add fresh rows here
-- against the current table and columns rather than restoring these.

-- ============================================================================
-- PAYMENT TRANSACTIONS (pre-retention-migration shape)
-- ============================================================================
--
-- The 20260508164247_add_retention_columns_to_payment_transactions migration:
--   1. Drops the NOT NULL FK on user_id and re-adds it as :nilify_all
--   2. Adds host_email, host_name, host_deleted_at columns
--   3. Backfills host_email/host_name via UPDATE ... FROM users WHERE pt.user_id = u.id
--   4. Creates an index on host_deleted_at
--
-- These rows exercise all three branches of the backfill.
--
-- Note: row 3 (orphaned user) bypasses the pre-migration FK using
-- session_replication_role so we can simulate a user deleted before the
-- migration ran. The FK is dropped as the first step of up/0, so this
-- state is valid once the migration proceeds.

-- Row 1: Standard row — user with a name. Backfill should populate both
-- host_email and host_name from the matching users row.
INSERT INTO payment_transactions (user_id, amount, status, stripe_id, metadata, inserted_at, updated_at)
SELECT id, 1999, 'succeeded', 'ch_seed_pt_1', '{}', NOW() - INTERVAL '10 days', NOW() - INTERVAL '10 days'
FROM users WHERE email = 'seed-user-1@example.com';

-- Row 2: User with NULL name. The backfill assigns NULL to host_name but
-- still populates host_email. Verifies the UPDATE tolerates NULL name.
INSERT INTO payment_transactions (user_id, amount, status, stripe_id, metadata, inserted_at, updated_at)
SELECT id, 999, 'succeeded', 'ch_seed_pt_2', '{}', NOW() - INTERVAL '9 days', NOW() - INTERVAL '9 days'
FROM users WHERE email = 'seed-user-2@example.com';

-- Row 3: User was hard-deleted before the migration ran. The UPDATE ... FROM
-- users WHERE pt.user_id = u.id finds no match, so host_email and host_name
-- remain NULL after the ALTER TABLE. Verifies the backfill does not abort
-- on orphaned rows. Uses session_replication_role to bypass the pre-migration
-- on_delete: :delete_all FK that would otherwise cascade-delete this row.
INSERT INTO users (id, email, password_hash, inserted_at, updated_at)
VALUES (999999999, 'deleted-seed-host@example.com', '$2b$12$K4fE6xkGz0qYkN2wQpYDOeG0G0G0G0G0G0G0G0G0G0G0G0G0G0', NOW() - INTERVAL '30 days', NOW() - INTERVAL '30 days');

INSERT INTO payment_transactions (user_id, amount, status, stripe_id, metadata, inserted_at, updated_at)
VALUES (999999999, 499, 'succeeded', 'ch_seed_pt_3', '{}', NOW() - INTERVAL '8 days', NOW() - INTERVAL '8 days');

SET session_replication_role = replica;
DELETE FROM users WHERE id = 999999999;
SET session_replication_role = DEFAULT;

-- ============================================================================
--
-- A seventh legacy `calendar_events` row lived here, covering the
-- add_attendee_notification_tracking backfill against a row whose every
-- referenced field is NULL or degenerate. Removed for the same reason as the
-- block above: the table is already `provider_calendar_events` by the time
-- this file is loaded, and that migration is out of the tested window.

-- ============================================================================
-- CONNECT ACCOUNTS
-- ============================================================================
--
-- These rows are present before:
--   * 20260508170000_add_connect_accounts_user_id_unique_index — adds a partial
--     unique index on user_id WHERE deleted_at IS NULL. The soft-deleted row
--     below verifies the index build tolerates non-live rows without treating
--     them as conflicts.
--   * 20260511084206_fix_connect_accounts_status_default — changes the column
--     default from "active" to "creating". Existing rows are not changed by the
--     migration; these rows verify the ALTER TABLE succeeds with live data.
--
-- Row 1: Active account — charges_enabled = true, live (deleted_at IS NULL).
-- Exercises the live-row branch of the partial unique index.
INSERT INTO connect_accounts (id, user_id, stripe_account_id, country, default_currency, charges_enabled, payouts_enabled, details_submitted, status, inserted_at, updated_at)
SELECT gen_random_uuid(),
       (SELECT id FROM users WHERE email = 'seed-user-1@example.com'),
       'acct_seed_active_1',
       'de',
       'eur',
       true,
       true,
       true,
       'active',
       NOW(),
       NOW();

-- Row 2: Soft-deleted account (deleted_at IS NOT NULL, user_id IS NULL after
-- nilify). The live-only partial unique index must not count this row against
-- the uniqueness constraint for user_id or stripe_account_id.
INSERT INTO connect_accounts (id, user_id, stripe_account_id, country, default_currency, charges_enabled, payouts_enabled, details_submitted, status, deleted_at, inserted_at, updated_at)
VALUES (gen_random_uuid(),
        NULL,
        'acct_seed_deleted_2',
        'de',
        'eur',
        false,
        false,
        false,
        'deleted',
        NOW() - INTERVAL '5 days',
        NOW() - INTERVAL '10 days',
        NOW() - INTERVAL '5 days');

-- ============================================================================
-- BOOKING PAYMENTS
-- ============================================================================
--
-- These rows are present before:
--   * 20260511084157_add_stale_pending_index_to_booking_payments — adds a
--     partial composite index on (status, inserted_at) WHERE status = 'pending'
--     AND stripe_checkout_session_id IS NOT NULL. The pending row below
--     exercises the index predicate.
--
-- host_user_id is a bare integer (no FK) so arbitrary values are safe.
-- meeting_id is nullable; all rows use NULL to avoid FK dependency on meetings.

-- Row 1: Pending payment with a checkout session ID.
-- Exercises the stale-pending index predicate (status = 'pending' AND
-- stripe_checkout_session_id IS NOT NULL).
INSERT INTO booking_payments (id, stripe_account_id, host_user_id, host_email, host_name, attendee_email, attendee_name, meeting_type_name, stripe_checkout_session_id, amount_cents, currency, application_fee_cents, status, refunded_amount_cents, inserted_at, updated_at)
VALUES (gen_random_uuid(),
        'acct_seed_active_1',
        1,
        'host-seed@example.com',
        'Seed Host',
        'attendee-seed@example.com',
        'Seed Attendee',
        'Discovery Call',
        'cs_seed_pending_1',
        5000,
        'eur',
        25,
        'pending',
        0,
        NOW() - INTERVAL '2 days',
        NOW() - INTERVAL '2 days');

-- Row 2: Paid payment with paid_at set. Baseline non-pending row.
INSERT INTO booking_payments (id, stripe_account_id, host_user_id, host_email, host_name, attendee_email, attendee_name, meeting_type_name, stripe_checkout_session_id, stripe_payment_intent_id, stripe_charge_id, amount_cents, currency, application_fee_cents, status, paid_at, refunded_amount_cents, inserted_at, updated_at)
VALUES (gen_random_uuid(),
        'acct_seed_active_1',
        1,
        'host-seed@example.com',
        'Seed Host',
        'attendee-seed2@example.com',
        'Seed Attendee 2',
        'Strategy Session',
        'cs_seed_paid_2',
        'pi_seed_paid_2',
        'ch_seed_paid_2',
        10000,
        'eur',
        50,
        'paid',
        NOW() - INTERVAL '1 day',
        0,
        NOW() - INTERVAL '1 day',
        NOW() - INTERVAL '1 day');

-- Row 3: Anonymised payment (host_deleted_at set, attendee_email NULL,
-- attendee_name NULL, meeting_type_name '[deleted]'). Exercises the
-- host_deleted_at index and verifies NULL attendee columns do not violate
-- any NOT NULL constraints.
INSERT INTO booking_payments (id, stripe_account_id, host_user_id, host_email, host_name, attendee_email, attendee_name, meeting_type_name, stripe_checkout_session_id, stripe_payment_intent_id, stripe_charge_id, amount_cents, currency, application_fee_cents, status, paid_at, refunded_amount_cents, host_deleted_at, inserted_at, updated_at)
VALUES (gen_random_uuid(),
        'acct_seed_deleted_2',
        99999,
        'deleted-host-seed@example.com',
        NULL,
        NULL,
        NULL,
        '[deleted]',
        'cs_seed_anon_3',
        'pi_seed_anon_3',
        'ch_seed_anon_3',
        7500,
        'eur',
        0,
        'paid',
        NOW() - INTERVAL '30 days',
        0,
        NOW() - INTERVAL '5 days',
        NOW() - INTERVAL '30 days',
        NOW() - INTERVAL '5 days');

-- Row 4: Fully refunded payment (refunded_amount_cents = amount_cents).
-- Exercises the refunded_amount_within_bounds check constraint and verifies
-- the index build handles the refunded status.
INSERT INTO booking_payments (id, stripe_account_id, host_user_id, host_email, host_name, attendee_email, attendee_name, meeting_type_name, stripe_checkout_session_id, stripe_payment_intent_id, stripe_charge_id, amount_cents, currency, application_fee_cents, status, paid_at, refunded_amount_cents, inserted_at, updated_at)
VALUES (gen_random_uuid(),
        'acct_seed_active_1',
        1,
        'host-seed@example.com',
        'Seed Host',
        'attendee-seed4@example.com',
        'Seed Attendee 4',
        'Coaching Call',
        'cs_seed_refunded_4',
        'pi_seed_refunded_4',
        'ch_seed_refunded_4',
        3000,
        'eur',
        15,
        'refunded',
        NOW() - INTERVAL '7 days',
        3000,
        NOW() - INTERVAL '7 days',
        NOW() - INTERVAL '7 days');

-- ============================================================================
-- MEETINGS
-- ============================================================================
--
-- These rows are present before:
--   * 20260616144719_add_meetings_utm_source_index — builds a partial composite
--     index on (organizer_user_id, utm_source) WHERE utm_source IS NOT NULL,
--     CONCURRENTLY. The rows below exercise the index predicate against a
--     populated table rather than an empty one: duplicate sources, a NULL
--     source that must be excluded, a 255-byte source at the column's validated
--     maximum, a multibyte-unicode source, and a NULL organizer (the leading
--     index column) — all of which the concurrent build must tolerate.
--
-- id is a uuid with no default, so each row supplies gen_random_uuid().
-- organizer_user_id references seed-user-1 via subquery (id-type-agnostic).
-- meeting_type_id is left NULL to avoid a FK dependency on meeting_types.

-- Rows 1-2: Same organizer + same utm_source. Duplicate keys in a non-unique
-- partial index — the ordinary booking-attribution shape.
INSERT INTO meetings (id, uid, title, start_time, end_time, organizer_name, organizer_email, attendee_name, attendee_email, organizer_user_id, utm_source, inserted_at, updated_at)
VALUES
  (gen_random_uuid(), 'seed-mtg-utm-1', 'Seed Meeting 1', NOW(), NOW() + INTERVAL '30 minutes', 'Seed Host', 'host-seed@example.com', 'Seed Attendee', 'att-seed-1@example.com', (SELECT id FROM users WHERE email = 'seed-user-1@example.com' LIMIT 1), 'linkedin', NOW(), NOW()),
  (gen_random_uuid(), 'seed-mtg-utm-2', 'Seed Meeting 2', NOW(), NOW() + INTERVAL '30 minutes', 'Seed Host', 'host-seed@example.com', 'Seed Attendee', 'att-seed-2@example.com', (SELECT id FROM users WHERE email = 'seed-user-1@example.com' LIMIT 1), 'linkedin', NOW(), NOW());

-- Row 3: utm_source NULL — must be EXCLUDED by the partial index predicate.
INSERT INTO meetings (id, uid, title, start_time, end_time, organizer_name, organizer_email, attendee_name, attendee_email, organizer_user_id, utm_source, inserted_at, updated_at)
VALUES (gen_random_uuid(), 'seed-mtg-utm-3', 'Seed Meeting 3', NOW(), NOW() + INTERVAL '30 minutes', 'Seed Host', 'host-seed@example.com', 'Seed Attendee', 'att-seed-3@example.com', (SELECT id FROM users WHERE email = 'seed-user-1@example.com' LIMIT 1), NULL, NOW(), NOW());

-- Row 4: utm_source at the 255-byte validated maximum — long btree key entry.
INSERT INTO meetings (id, uid, title, start_time, end_time, organizer_name, organizer_email, attendee_name, attendee_email, organizer_user_id, utm_source, inserted_at, updated_at)
VALUES (gen_random_uuid(), 'seed-mtg-utm-4', 'Seed Meeting 4', NOW(), NOW() + INTERVAL '30 minutes', 'Seed Host', 'host-seed@example.com', 'Seed Attendee', 'att-seed-4@example.com', (SELECT id FROM users WHERE email = 'seed-user-1@example.com' LIMIT 1), repeat('a', 255), NOW(), NOW());

-- Row 5: Multibyte-unicode utm_source — verifies byte-vs-char handling.
INSERT INTO meetings (id, uid, title, start_time, end_time, organizer_name, organizer_email, attendee_name, attendee_email, organizer_user_id, utm_source, inserted_at, updated_at)
VALUES (gen_random_uuid(), 'seed-mtg-utm-5', 'Seed Meeting 5', NOW(), NOW() + INTERVAL '30 minutes', 'Seed Host', 'host-seed@example.com', 'Seed Attendee', 'att-seed-5@example.com', (SELECT id FROM users WHERE email = 'seed-user-1@example.com' LIMIT 1), 'naïve–utm-源', NOW(), NOW());

-- Row 6: NULL organizer (the leading index column) with a non-null utm_source.
-- A composite index tolerates NULLs in the leading column; the concurrent build
-- must not choke on it.
INSERT INTO meetings (id, uid, title, start_time, end_time, organizer_name, organizer_email, attendee_name, attendee_email, organizer_user_id, utm_source, inserted_at, updated_at)
VALUES (gen_random_uuid(), 'seed-mtg-utm-6', 'Seed Meeting 6', NOW(), NOW() + INTERVAL '30 minutes', 'Seed Host', 'host-seed@example.com', 'Seed Attendee', 'att-seed-6@example.com', NULL, 'direct', NOW(), NOW());
