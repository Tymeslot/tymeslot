defmodule Tymeslot.Repo.Migrations.SeedDefaultMeetingTypesForProfilesWithoutAny do
  @moduledoc """
  Gives every profile that has no meeting type at all the two default ones,
  once.

  The defaults used to be created lazily, the first time the owner's
  meeting types were listed, and again whenever the owner had deleted them
  all. They are now seeded once, when the profile is created, and never
  again. Under the old rule any profile that had ever been listed has at
  least one meeting type, so a profile with none was never seeded: this
  seeds it exactly as the lazy seed would have, and a host who deletes the
  defaults afterwards keeps none.

  Mirrors `MeetingTypes`' default templates ("15 Minutes" and "30 Minutes",
  one in-person location each, a 30-minute reminder) and the lazy seed's
  calendar choice: the profile's primary calendar integration and its
  default booking calendar, when both are set. It cannot check, as the lazy
  seed did, that the integration's credentials still decrypt; such a type
  then waits for the owner to pick a calendar, as any type with a
  disconnected calendar does.

  The lazy seed also ran the booking page publish check, so a profile with
  a username that this seeds is stamped `booking_page_published_at` here.
  The publish telemetry is not emitted: it counts hosts making their page
  live, and this is a backfill, as the earlier publish backfill was.

  An account waiting to be deleted is skipped: it is frozen, and its rows go
  with it. Rolling back leaves the seeded meeting types in place, since the
  owner may already have edited or booked them.
  """

  use Ecto.Migration

  def up do
    # A one-shot data backfill across three tables; neither an INSERT ...
    # SELECT nor the UPDATE driven by its RETURNING has a migration DSL form.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    WITH seeded AS (
      INSERT INTO meeting_types (
        user_id, name, description, duration_minutes, icon, sort_order,
        is_active, allow_video, locations, calendar_integration_id,
        target_calendar_id, reminder_config, inserted_at, updated_at
      )
      SELECT
        p.user_id, d.name, d.description, d.duration_minutes, d.icon, d.sort_order,
        true, false,
        ARRAY[jsonb_build_object(
          'id', gen_random_uuid()::text,
          'kind', 'in_person',
          'label', 'In person',
          'details', NULL,
          'collect_from_guest', false,
          'video_integration_ids', '[]'::jsonb,
          'venue_ids', '[]'::jsonb,
          'position', 0
        )],
        cal.id, cal.default_booking_calendar_id,
        ARRAY[jsonb_build_object('value', 30, 'unit', 'minutes')],
        date_trunc('second', now() AT TIME ZONE 'utc'),
        date_trunc('second', now() AT TIME ZONE 'utc')
      FROM profiles p
      JOIN users u ON u.id = p.user_id AND u.deletion_requested_at IS NULL
      CROSS JOIN (
        VALUES
          ('15 Minutes', 'Quick chat or brief consultation', 15, 'hero-bolt', 0),
          ('30 Minutes', 'In-depth discussion or detailed review', 30, 'hero-rocket-launch', 1)
      ) AS d(name, description, duration_minutes, icon, sort_order)
      LEFT JOIN calendar_integrations cal
        ON cal.id = p.primary_calendar_integration_id
       AND cal.user_id = p.user_id
       AND cal.default_booking_calendar_id IS NOT NULL
      WHERE NOT EXISTS (SELECT 1 FROM meeting_types mt WHERE mt.user_id = p.user_id)
      ON CONFLICT (user_id, name) DO NOTHING
      RETURNING user_id
    )
    UPDATE profiles
    SET booking_page_published_at = date_trunc('second', now() AT TIME ZONE 'utc')
    WHERE user_id IN (SELECT user_id FROM seeded)
      AND booking_page_published_at IS NULL
      AND username IS NOT NULL
      AND username <> ''
    """)
  end

  def down, do: :ok
end
