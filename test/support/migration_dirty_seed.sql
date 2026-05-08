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
--
-- Tables seeded: users, profiles, calendar_integrations, video_integrations,
--                calendar_events (renamed to provider_calendar_events by migration)

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
-- CALENDAR INTEGRATIONS
-- ============================================================================

-- Regression: duplicate active CalDAV integrations for the same user+provider
-- (caused unique_active_calendar_null_account_per_user failure in v0.99.x)
INSERT INTO calendar_integrations (user_id, provider, base_url, name, is_active, verify_ssl, calendar_paths, calendar_list, inserted_at, updated_at)
SELECT id, 'caldav', 'https://dav.example.com', 'CalDAV Server 1', true, true, '{}', ARRAY[]::jsonb[], NOW(), NOW()
FROM users WHERE email = 'seed-user-1@example.com';

INSERT INTO calendar_integrations (user_id, provider, base_url, name, is_active, verify_ssl, calendar_paths, calendar_list, inserted_at, updated_at)
SELECT id, 'caldav', 'https://dav.example.com', 'CalDAV Server 2', true, true, '{}', ARRAY[]::jsonb[], NOW(), NOW()
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

-- Two active MiroTalk integrations for the same user (duplicate provider)
INSERT INTO video_integrations (user_id, provider, base_url, name, is_active, settings, inserted_at, updated_at)
SELECT id, 'mirotalk', 'https://meet1.example.com', 'MiroTalk 1', true, '{}'::jsonb, NOW(), NOW()
FROM users WHERE email = 'seed-user-1@example.com';

INSERT INTO video_integrations (user_id, provider, base_url, name, is_active, settings, inserted_at, updated_at)
SELECT id, 'mirotalk', 'https://meet2.example.com', 'MiroTalk 2', true, '{}'::jsonb, NOW(), NOW()
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
-- CALENDAR EVENTS (legacy shape)
-- ============================================================================
--
-- Released v0.99.x shipped a `calendar_events` table; the
-- 20260408110831_recreate_provider_calendar_events migration renames it to
-- `provider_calendar_events` and adds four new NOT NULL constraints
-- (provider, synced_at, transparency, status). These rows exercise the
-- backfill and catch-all NULL guards in that migration.
--
-- Note: inserts target the legacy `calendar_events` table — this seed
-- runs after `create_calendar_events` but before `recreate_provider_calendar_events`.
--
-- 20260408110831_recreate_provider_calendar_events adds a NOT NULL `created_by_tymeslot`
-- column with `default: false`. No explicit value is included here because the column
-- does not exist in `calendar_events` at insert time; the column default backfills all
-- pre-existing rows automatically when the migration runs.

-- Baseline legacy row: title set, synced_at populated — happy path.
INSERT INTO calendar_events (uid, calendar_integration_id, calendar_path, title, start_at, end_at, all_day, status, synced_at, inserted_at, updated_at)
SELECT 'seed-evt-baseline@example.com',
       (SELECT id FROM calendar_integrations WHERE name = 'CalDAV Server 1' LIMIT 1),
       '/calendars/user1/default/',
       'Baseline event',
       NOW() + INTERVAL '1 day',
       NOW() + INTERVAL '1 day 1 hour',
       false,
       'confirmed',
       NOW(),
       NOW(),
       NOW();

-- Regression: synced_at IS NULL — migration must backfill from inserted_at
-- before applying the NOT NULL constraint.
INSERT INTO calendar_events (uid, calendar_integration_id, calendar_path, title, start_at, end_at, all_day, status, synced_at, inserted_at, updated_at)
SELECT 'seed-evt-null-synced@example.com',
       (SELECT id FROM calendar_integrations WHERE name = 'CalDAV Server 1' LIMIT 1),
       '/calendars/user1/default/',
       'Never-synced legacy row',
       NOW() + INTERVAL '2 days',
       NOW() + INTERVAL '2 days 30 minutes',
       false,
       NULL,
       NULL,
       NOW(),
       NOW();

-- Regression: calendar_path IS NULL — provider_calendar_id backfill must
-- fall through to 'primary' rather than leaving the column NULL.
INSERT INTO calendar_events (uid, calendar_integration_id, calendar_path, title, start_at, end_at, all_day, status, synced_at, inserted_at, updated_at)
SELECT 'seed-evt-null-path@example.com',
       (SELECT id FROM calendar_integrations WHERE name = 'Nextcloud' LIMIT 1),
       NULL,
       'No calendar_path',
       NOW() + INTERVAL '3 days',
       NOW() + INTERVAL '3 days 45 minutes',
       false,
       'tentative',
       NOW(),
       NOW(),
       NOW();

-- Regression: title IS NULL — summary backfill must tolerate it.
INSERT INTO calendar_events (uid, calendar_integration_id, calendar_path, title, start_at, end_at, all_day, status, synced_at, inserted_at, updated_at)
SELECT 'seed-evt-null-title@example.com',
       (SELECT id FROM calendar_integrations WHERE name = 'Radicale' LIMIT 1),
       '/cal/default/',
       NULL,
       NOW() + INTERVAL '4 days',
       NOW() + INTERVAL '4 days 1 hour',
       true,
       'confirmed',
       NOW(),
       NOW(),
       NOW();

-- 20260415185057_add_sync_state_to_provider_calendar_events adds four columns
-- to provider_calendar_events: sync_state NOT NULL DEFAULT 'synced',
-- sync_attempts NOT NULL DEFAULT 0, sync_last_attempt_at (nullable), and
-- sync_last_error (nullable). All have constant or nullable defaults — no
-- explicit values are required in the seed INSERTs, and the column defaults
-- backfill all pre-existing rows automatically when the migration runs.

-- Regression: status IS NULL — existing UPDATE must default to 'confirmed'.
INSERT INTO calendar_events (uid, calendar_integration_id, calendar_path, title, start_at, end_at, all_day, status, synced_at, inserted_at, updated_at)
SELECT 'seed-evt-null-status@example.com',
       (SELECT id FROM calendar_integrations WHERE name = 'CalDAV Server 2' LIMIT 1),
       '/calendars/user1/other/',
       'Null status',
       NOW() + INTERVAL '5 days',
       NOW() + INTERVAL '5 days 20 minutes',
       false,
       NULL,
       NOW(),
       NOW(),
       NOW();

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

-- Regression: add_attendee_notification_tracking backfill must survive rows
-- where every field the backfill references is NULL or degenerate. title,
-- description, location are all NULL (so the rename migration leaves summary
-- NULL too); start_at equals end_at (zero-duration); attendees contains one
-- entry with whitespace-padded email to prove to_jsonb(attendees) copes with
-- any valid jsonb array content. The backfill uses COALESCE(to_jsonb(col),
-- 'null'::jsonb) on every scalar column, so NULLs must become JSON null and
-- not raise.
INSERT INTO calendar_events (uid, calendar_integration_id, calendar_path, title, description, location, start_at, end_at, all_day, attendees, status, synced_at, inserted_at, updated_at)
SELECT 'seed-evt-attnotif-adversarial@example.com',
       (SELECT id FROM calendar_integrations WHERE name = 'CalDAV Server 1' LIMIT 1),
       '/calendars/user1/default/',
       NULL,
       NULL,
       NULL,
       TIMESTAMP '2099-12-31 23:59:59',
       TIMESTAMP '2099-12-31 23:59:59',
       false,
       ARRAY['{"email":"  dirty@example.com  ","name":null}'::jsonb],
       'confirmed',
       NOW(),
       NOW(),
       NOW();
