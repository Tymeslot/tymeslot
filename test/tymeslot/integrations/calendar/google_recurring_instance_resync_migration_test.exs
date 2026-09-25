defmodule Tymeslot.Integrations.Calendar.GoogleRecurringInstanceResyncMigrationTest do
  @moduledoc """
  Covers the migration that clears the collapsed cache rows of Google recurring
  series and drops Google sync tokens, so the next sync bootstraps and caches
  every instance under its own UID.

  Both boundaries are asserted. Clear too little and the collapsed row lingers
  beside the per-instance rows the next sync writes, while a surviving sync
  token means the unchanged instances never arrive at all. Clear too much and
  a Google single event, or another provider's recurring occurrence, vanishes
  from the grid for no reason, and a non-Google integration loses sync state
  it has no way to rebuild through Google's bootstrap.

  The migration is driven from `priv` (`MigrationRunner.replay!/2`, since its
  `down/0` is a deliberate no-op) so the assertions are about the SQL that
  ships rather than a pasted copy of it. See `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :calendar
  @moduletag :migrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  alias Tymeslot.Test.MigrationRunner

  @version 20_260_925_083_349

  describe "up/0" do
    test "deletes the collapsed Google series row and nothing else" do
      google = insert(:calendar_integration, provider: "google")
      caldav = insert(:calendar_integration, provider: "caldav")

      collapsed =
        insert(:provider_calendar_event,
          calendar_integration: google,
          provider: "google",
          uid: "series123@google.com",
          recurring_event_id: "series123"
        )

      google_single =
        insert(:provider_calendar_event,
          calendar_integration: google,
          provider: "google",
          uid: "single456@google.com",
          recurring_event_id: nil
        )

      caldav_occurrence =
        insert(:provider_calendar_event,
          calendar_integration: caldav,
          provider: "caldav",
          uid: "abc-123_20260904T140000",
          recurring_event_id: "abc-123"
        )

      MigrationRunner.replay!(@version)

      assert Repo.get(ProviderCalendarEventSchema, collapsed.id) == nil
      assert Repo.get(ProviderCalendarEventSchema, google_single.id)
      assert Repo.get(ProviderCalendarEventSchema, caldav_occurrence.id)
    end

    test "drops the Google sync token so the next sync bootstraps" do
      google = insert(:calendar_integration, provider: "google", google_sync_token: "tok-google")

      MigrationRunner.replay!(@version)

      assert %CalendarIntegrationSchema{google_sync_token: nil} = Repo.reload!(google)
    end

    test "leaves a sync token on a non-Google integration alone" do
      outlook = insert(:calendar_integration, provider: "outlook", google_sync_token: "tok-stray")

      MigrationRunner.replay!(@version)

      assert Repo.reload!(outlook).google_sync_token == "tok-stray"
    end
  end
end
