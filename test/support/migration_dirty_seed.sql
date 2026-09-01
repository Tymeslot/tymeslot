-- migration_dirty_seed.sql
--
-- Adversarial data for migration testing. dirty_seed_migration_test.exs
-- migrates a scratch database to the pinned version below, loads this file, and
-- then runs every remaining migration, to verify they handle real-world data
-- shapes rather than only an empty database.
--
-- SEED SCHEMA VERSION: 20260702180350
--
-- That line is the schema this file is written against, and it is fixed. The
-- test module's @seed_schema_version is the authority and asserts the two
-- match; treat this copy as a note to whoever is editing the SQL.
--
-- MAINTENANCE RULES:
-- 1. When a migration bug is found in production, add the offending data
--    pattern here as a regression case.
-- 2. Write every INSERT against the schema as of the pinned version above, not
--    against today's schema. A later migration adding a NOT NULL column or a
--    constraint needs no change here — having to cope with rows that predate it
--    is exactly what it is being tested for.
-- 3. Every INSERT must use explicit column lists — never INSERT INTO t VALUES.
-- 4. Comments explain WHY each row is adversarial, not what it contains.
-- 5. Rows are never retired for age. A row written for a migration that has
--    long since shipped still gives every later migration touching that table a
--    populated table to run against, which is the failure this file exists to
--    catch. Delete a row only when it is genuinely unreachable.
-- 6. Moving the pin forward is the one change that can invalidate rows here,
--    and it is needed only to seed a table or column that did not exist at the
--    pin. When you move it, run the test and repair whatever the newer schema
--    rejects — deliberately, checking what each rejected row covered.
--
-- Tables seeded: users, profiles, user_sessions, calendar_integrations,
--                video_integrations, provider_calendar_events, connect_accounts,
--                payment_transactions, booking_payments, meetings,
--                weekly_availability, availability_breaks,
--                availability_overrides

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
-- index unique_active_calendar_null_account_per_user. That migration is before
-- the pinned version, so the index already exists when this file loads and
-- rejects the duplicate outright. The surviving row stays: it is what any later
-- migration touching calendar_integrations runs against.
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
-- unique_active_video_null_account_per_user. Both are before the pinned
-- version, so the index exists when this file loads and rejects the twin. The
-- surviving row stays as populated data for later migrations.
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
-- PROVIDER CALENDAR EVENTS
-- ============================================================================
--
-- The synced calendar cache. Written against the post-rename table: the rename
-- (20260408110831_recreate_provider_calendar_events) and the columns added
-- through 20260415185057_add_sync_state_to_provider_calendar_events are all
-- before the pin, so the table these rows load into already carries its full
-- NOT NULL set. Only `uid`, `provider`, `provider_calendar_id` and `synced_at`
-- have no default and must be supplied; the rest are deliberately omitted from
-- some column lists so their defaults are exercised too.
--
-- This is the largest table on a real installation and the one migrations
-- reach for most, so an empty one lets a migration pass by touching nothing.
-- The shapes below are the ones a migration can trip over: the two mutually
-- exclusive ways a row expresses its timing, a row carrying almost no data at
-- all, and the columns that decide whether a row blocks time.
--
-- Note `start_at`, `end_at` and `synced_at` are still naive `timestamp` at the
-- pin — only `inserted_at`/`updated_at` were converted to `timestamptz`, by the
-- pinned migration itself. Literals here are UTC wall-clock accordingly.

-- All-day row: the timing shape that has no timestamps at all. The released
-- `calendar_events` table had start_at/end_at NOT NULL, so any migration that
-- reasons about "when does this event happen" by reading them alone silently
-- skips this row, and any migration that re-tightens them rejects it outright.
INSERT INTO provider_calendar_events (calendar_integration_id, uid, provider, provider_calendar_id, provider_event_id, summary, all_day, start_date, end_date, timezone, status, transparency, etag, synced_at, inserted_at, updated_at)
SELECT ci.id, 'seed-pce-allday@example.com', 'caldav', '/luka/main-calendar/', '/luka/main-calendar/allday.ics', 'Company offsite', true, '2026-07-06', '2026-07-08', 'Europe/Berlin', 'confirmed', 'opaque', '"etag-allday-1"', '2026-07-01 06:15:00', NOW(), NOW()
FROM calendar_integrations ci
JOIN users u ON u.id = ci.user_id
WHERE u.email = 'seed-user-1@example.com' AND ci.name = 'CalDAV Server 1';

-- Timed row on the same integration: the inverse shape, and a second uid under
-- one calendar_integration_id, which is what the unique index is on. A
-- recurring master with an exception list and a non-empty attendees array, so
-- a migration rewriting either array type meets values rather than empties.
INSERT INTO provider_calendar_events (calendar_integration_id, uid, provider, provider_calendar_id, provider_event_id, summary, description, location, all_day, start_at, end_at, timezone, status, transparency, organiser, attendees, recurrence_rule, recurrence_exceptions, recurring_event_id, etag, synced_at, provider_updated_at, inserted_at, updated_at)
SELECT ci.id, 'seed-pce-timed@example.com', 'caldav', '/luka/main-calendar/', '/luka/main-calendar/weekly.ics', 'Weekly planning', 'Standing agenda in the shared doc.', 'Meeting room 2', false, '2026-07-02 09:00:00', '2026-07-02 10:00:00', 'Europe/Berlin', 'confirmed', 'opaque', '{"email":"organiser@example.com","name":"Organiser"}'::jsonb, ARRAY['{"email":"attendee@example.com","status":"accepted"}'::jsonb], 'FREQ=WEEKLY;BYDAY=TH', ARRAY['2026-07-16'::date], 'seed-pce-timed@example.com', '"etag-timed-1"', '2026-07-01 06:15:00', '2026-06-30 11:00:00', NOW(), NOW()
FROM calendar_integrations ci
JOIN users u ON u.id = ci.user_id
WHERE u.email = 'seed-user-1@example.com' AND ci.name = 'CalDAV Server 1';

-- The degenerate row: every nullable column left NULL, including summary,
-- location, etag and provider_event_id, and neither timing shape filled in, so
-- it occupies no time and identifies nothing. Providers do return rows this
-- thin. It also reuses the all-day row's uid under a different integration,
-- which the (calendar_integration_id, uid) index must allow — a migration that
-- re-creates that index without the integration column fails here.
INSERT INTO provider_calendar_events (calendar_integration_id, uid, provider, provider_calendar_id, synced_at, inserted_at, updated_at)
SELECT ci.id, 'seed-pce-allday@example.com', 'nextcloud', '/remote.php/dav/calendars/luka/personal/', '2026-07-01 06:20:00', NOW(), NOW()
FROM calendar_integrations ci
JOIN users u ON u.id = ci.user_id
WHERE u.email = 'seed-user-1@example.com' AND ci.name = 'Nextcloud';

-- Cancelled row, still in the cache. `status` and `transparency` are the two
-- columns that decide whether a row blocks time, so a migration that filters
-- or backfills availability data has to meet a row it must not count. Paired
-- with a sync_state that is not "synced", which is the queue the sync workers
-- select on.
INSERT INTO provider_calendar_events (calendar_integration_id, uid, provider, provider_calendar_id, provider_event_id, summary, all_day, start_at, end_at, status, transparency, sync_state, sync_attempts, sync_last_attempt_at, sync_last_error, etag, synced_at, inserted_at, updated_at)
SELECT ci.id, 'seed-pce-cancelled@example.com', 'nextcloud', '/remote.php/dav/calendars/luka/personal/', 'nc-cancelled-1', 'Cancelled review', false, '2026-07-03 13:00:00', '2026-07-03 14:00:00', 'cancelled', 'opaque', 'locally_deleted', 3, '2026-07-01 06:22:00', 'server returned 507 insufficient storage', NULL, '2026-07-01 06:20:00', NOW(), NOW()
FROM calendar_integrations ci
JOIN users u ON u.id = ci.user_id
WHERE u.email = 'seed-user-1@example.com' AND ci.name = 'Nextcloud';

-- Transparent row on a deactivated integration: the other half of the
-- blocks-time pair, hanging off a parent that is_active = false. A migration
-- that backfills through calendar_integrations with an active-only join skips
-- this row, and a later NOT NULL on whatever it skipped then fails.
INSERT INTO provider_calendar_events (calendar_integration_id, uid, provider, provider_calendar_id, provider_event_id, summary, all_day, start_at, end_at, status, transparency, visibility, colour, synced_at, inserted_at, updated_at)
SELECT ci.id, 'seed-pce-transparent@example.com', 'caldav', '/luka/archive/', '/luka/archive/oldbooking.ics', 'Out of office (informational)', false, '2026-06-20 08:00:00', '2026-06-20 17:00:00', 'confirmed', 'transparent', 'private', '#7c3aed', '2026-06-19 22:05:00', NOW(), NOW()
FROM calendar_integrations ci
JOIN users u ON u.id = ci.user_id
WHERE u.email = 'seed-user-1@example.com' AND ci.name = 'Deactivated';

-- Second user, third provider, and the Tymeslot-authored shape: a row this
-- application wrote rather than read, linked to a video integration and
-- carrying its raw iCalendar body. `provider_event_id` is a CalDAV href rooted
-- at a collection the parent integration does not list in calendar_paths,
-- which is the case a migration repairing misfiled rows from the href must
-- leave alone rather than guess at. The summary is deliberately past 255 bytes:
-- these columns are `text` from 20260417062658, and anything that narrows them
-- again has to fail loudly here.
INSERT INTO provider_calendar_events (calendar_integration_id, video_integration_id, uid, provider, provider_calendar_id, provider_event_id, summary, description, location, all_day, start_at, end_at, timezone, status, transparency, video_link, raw_ical, created_by_tymeslot, sync_state, ical_sequence, last_notified_state, provider_metadata, attendees, synced_at, inserted_at, updated_at)
SELECT ci.id,
       (SELECT vi.id FROM video_integrations vi WHERE vi.user_id = u.id AND vi.name = 'Old MiroTalk'),
       'seed-pce-tymeslot@example.com', 'radicale', '/luka/bookings/', '/luka/unlisted-collection/booking.ics',
       repeat('Discovery call with a customer whose calendar entry title nobody trimmed ', 12),
       'Booked through Tymeslot.', 'https://old-meet.example.com/room/abc', false, '2026-07-09 15:30:00', '2026-07-09 16:00:00', 'UTC', 'tentative', 'opaque',
       'https://old-meet.example.com/room/abc',
       'BEGIN:VCALENDAR' || chr(13) || chr(10) || 'BEGIN:VEVENT' || chr(13) || chr(10) || 'UID:seed-pce-tymeslot@example.com' || chr(13) || chr(10) || 'END:VEVENT' || chr(13) || chr(10) || 'END:VCALENDAR',
       true, 'locally_created', 4,
       '{"title":"Discovery call","attendees":["attendee@example.com"]}'::jsonb,
       '{"source":"seed","etag_missing":true}'::jsonb,
       ARRAY['{"email":"attendee@example.com","status":"needs-action"}'::jsonb],
       '2026-07-08 20:00:00', NOW(), NOW()
FROM calendar_integrations ci
JOIN users u ON u.id = ci.user_id
WHERE u.email = 'seed-user-2@example.com' AND ci.name = 'Radicale';

-- ============================================================================
-- PAYMENT TRANSACTIONS (pre-retention-migration shape)
-- ============================================================================
--
-- Written for 20260508164247_add_retention_columns_to_payment_transactions,
-- which is now before the pin, so these rows no longer exercise it. They are
-- kept under maintenance rule 5: they are what a later migration touching
-- payment_transactions will meet. The original rationale, still the reason each
-- row has the shape it has:
--
-- The migration:
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
-- CONNECT ACCOUNTS
-- ============================================================================
--
-- Written for the two migrations below, both now before the pin, so these rows
-- no longer exercise them; they are kept under maintenance rule 5 as populated
-- data for later migrations. The shapes they were chosen for:
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
-- Written for the migration below, now before the pin, so these rows no longer
-- exercise it; they are kept under maintenance rule 5 as populated data for
-- later migrations. The shapes they were chosen for:
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
-- Written for the migration below, now before the pin, so these rows no longer
-- exercise it; they are kept under maintenance rule 5, and meetings is a table
-- migrations touch often. The shapes they were chosen for:
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

-- ============================================================================
-- PROFILE WITH NULL SCHEDULING POLICY
-- ============================================================================
--
-- buffer_minutes, advance_booking_days and min_advance_hours were created with
-- column defaults but never NOT NULL, so a database that wrote them explicitly
-- as NULL is reachable. 20260811180804_create_availability_schedules COALESCEs
-- each one while copying it onto the profile's new default schedule; without a
-- row like this the COALESCE is never executed and a regression to a bare copy
-- would pass. Seeded on user 3, whose profile is created here rather than above
-- so the NULL policy stays next to the reason for it.
INSERT INTO profiles (user_id, timezone, buffer_minutes, advance_booking_days, min_advance_hours, inserted_at, updated_at)
SELECT id, 'America/New_York', NULL, NULL, NULL, NOW(), NOW() FROM users WHERE email = 'seed-user-3@example.com';

-- ============================================================================
-- WEEKLY AVAILABILITY, BREAKS AND OVERRIDES
-- ============================================================================
--
-- 20260811181002_rekey_availability_to_schedules moves both child tables off
-- profile_id and onto the schedule_id of their profile's new default schedule,
-- then makes the column NOT NULL and drops profile_id. The backfill can only be
-- shown to preserve rows against a populated table: on an empty one the UPDATEs
-- match nothing, the orphan sweep deletes nothing, and the migration passes
-- having proved only that the DDL parses.
--
-- Every profile above is seeded, including the NULL-policy one, so the rekey is
-- exercised across more than one schedule and cannot pass by re-pointing
-- everything at whichever schedule it found first.

-- A full seven-day week per profile: five available weekdays with hours, two
-- unavailable weekend days with NULL times. day_of_week is unique per profile
-- before the migration and must stay unique per schedule after it, so this also
-- covers the index swap carrying real duplicates-per-profile across.
INSERT INTO weekly_availability (profile_id, day_of_week, is_available, start_time, end_time, inserted_at, updated_at)
SELECT p.id, d, d <= 5,
       CASE WHEN d <= 5 THEN TIME '09:00' END,
       CASE WHEN d <= 5 THEN TIME '17:30' END,
       NOW(), NOW()
FROM profiles p CROSS JOIN generate_series(1, 7) AS d;

-- Breaks hang off weekly_availability, not off the schedule, so they are only
-- reachable after the rekey if their parent row survived it with its id intact.
INSERT INTO availability_breaks (weekly_availability_id, start_time, end_time, label, sort_order, inserted_at, updated_at)
SELECT wa.id, TIME '12:00', TIME '13:00', 'Lunch', 0, NOW(), NOW()
FROM weekly_availability wa WHERE wa.day_of_week = 1;

-- One override of each type the check constraint allows. 'custom_hours' is the
-- only one carrying times, and the (profile_id, date) unique index becomes
-- (schedule_id, date), so three dates per profile prove the swap keeps them.
INSERT INTO availability_overrides (profile_id, date, override_type, start_time, end_time, reason, inserted_at, updated_at)
SELECT p.id, DATE '2026-12-24', 'unavailable', NULL, NULL, 'Christmas Eve', NOW(), NOW() FROM profiles p;

INSERT INTO availability_overrides (profile_id, date, override_type, start_time, end_time, reason, inserted_at, updated_at)
SELECT p.id, DATE '2026-12-31', 'custom_hours', TIME '10:00', TIME '14:00', 'Short day', NOW(), NOW() FROM profiles p;

INSERT INTO availability_overrides (profile_id, date, override_type, start_time, end_time, reason, inserted_at, updated_at)
SELECT p.id, DATE '2027-01-02', 'available', NULL, NULL, NULL, NOW(), NOW() FROM profiles p;
