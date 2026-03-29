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
-- Tables seeded: users, profiles, calendar_integrations, video_integrations

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
