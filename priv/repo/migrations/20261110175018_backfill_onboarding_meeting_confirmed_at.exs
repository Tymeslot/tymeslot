defmodule Tymeslot.Repo.Migrations.BackfillOnboardingMeetingConfirmedAt do
  @moduledoc """
  Stamps `onboarding_meeting_confirmed_at` for hosts already mid-onboarding
  who have plainly been through the meeting step, so the new gate does not
  send them back to it.

  A host counts when an active meeting type no longer matches a seeded
  default. A default is the wizard's editable fields as a seed wrote them, a
  name with its duration and one in-person location, and there have been two
  generations of seed:

    * "15 Minutes" (15) and "30 Minutes" (30), the pair seeded until November
      2026, in English whatever the sign-up's language;
    * "Intro call" (30), seeded since then in the language of the sign-up.

  The names are restated rather than read from the catalogue, so the migration
  means the same thing however the catalogue changes later.

  A host still on an untouched default cannot be told from one who never saw
  the step, and is left to confirm it once. Completed accounts are not stamped:
  `Tymeslot.Onboarding.meeting_step_confirmed?/1` counts them as confirmed. A
  host who confirmed the step since the column was added keeps that time, which
  also makes the migration safe to run twice. Rolling back leaves the stamps,
  which the column's own rollback removes.
  """
  use Ecto.Migration

  def up do
    # A one-shot data backfill reading a second table, which has no migration
    # DSL form. It runs apart from the column's migration, so it takes row
    # locks only, and it writes only accounts still in onboarding, a small set.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE users AS u
    SET onboarding_meeting_confirmed_at = NOW() AT TIME ZONE 'UTC'
    WHERE u.onboarding_meeting_confirmed_at IS NULL
      AND u.onboarding_completed_at IS NULL
      AND EXISTS (
        SELECT 1
        FROM meeting_types AS mt
        WHERE mt.user_id = u.id
          AND mt.is_active
          AND (
            ((mt.name, mt.duration_minutes) IN (
              ('15 Minutes', 15),
              ('30 Minutes', 30),
              ('Intro call', 30),
              ('Úvodní hovor', 30),
              ('Kennenlerngespräch', 30),
              ('Llamada de presentación', 30),
              ('Appel découverte', 30),
              ('Chiamata introduttiva', 30),
              ('Rozmowa wstępna', 30),
              ('Conversa inicial', 30),
              ('Ознайомча розмова', 30)
            )) IS NOT TRUE
            OR (cardinality(mt.locations) = 1 AND mt.locations[1] ->> 'kind' = 'in_person') IS NOT TRUE
          )
      )
    """)
  end

  def down, do: :ok
end
