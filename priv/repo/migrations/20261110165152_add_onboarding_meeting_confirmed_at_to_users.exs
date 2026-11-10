defmodule Tymeslot.Repo.Migrations.AddOnboardingMeetingConfirmedAtToUsers do
  @moduledoc """
  Records that a host got through the onboarding meeting step, which until now
  left no trace on the account, so the look and live steps can wait for it.

  A host already mid-onboarding has no marker, and the new gate would send them
  back to the meeting step. Those whose active meeting type no longer matches
  the seeded default have plainly been there, so they are stamped here. A host
  still on the untouched default cannot be told from one who never saw the
  step, and is left to confirm it once. Completed accounts are not stamped:
  `Tymeslot.Onboarding.meeting_step_confirmed?/1` counts them as confirmed.

  The seeded default is the wizard's three editable fields as
  `Tymeslot.MeetingTypes.Defaults` writes them: 30 minutes, one in-person
  location, and "Intro call" in the language of the sign-up. The translations
  are restated rather than read from the catalogue, so the migration means the
  same thing however the catalogue changes later.
  """
  use Ecto.Migration

  # The backfill is raw SQL by nature and is the reason this is safe to deploy.
  # It only writes accounts that have not finished onboarding, a small set.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  def up do
    alter table(:users) do
      add(:onboarding_meeting_confirmed_at, :utc_datetime)
    end

    execute("""
    UPDATE users AS u
    SET onboarding_meeting_confirmed_at = NOW() AT TIME ZONE 'UTC'
    WHERE u.onboarding_completed_at IS NULL
      AND EXISTS (
        SELECT 1
        FROM meeting_types AS mt
        WHERE mt.user_id = u.id
          AND mt.is_active
          AND (
            mt.duration_minutes IS DISTINCT FROM 30
            OR (mt.name = ANY(ARRAY[
              'Intro call',
              'Úvodní hovor',
              'Kennenlerngespräch',
              'Llamada de presentación',
              'Appel découverte',
              'Chiamata introduttiva',
              'Rozmowa wstępna',
              'Conversa inicial',
              'Ознайомча розмова'
            ])) IS NOT TRUE
            OR (cardinality(mt.locations) = 1 AND mt.locations[1] ->> 'kind' = 'in_person') IS NOT TRUE
          )
      )
    """)
  end

  def down do
    alter table(:users) do
      # Rolling back drops the column this migration added; nothing else reads it.
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove(:onboarding_meeting_confirmed_at)
    end
  end
end
