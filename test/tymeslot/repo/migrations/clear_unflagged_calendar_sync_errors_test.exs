defmodule Tymeslot.Repo.Migrations.ClearUnflaggedCalendarSyncErrorsTest do
  @moduledoc """
  A calendar card shows its stored sync failure while syncs keep failing, so
  the text earlier releases stored there must not survive the upgrade,
  except the reason a flagged integration awaits reconnection for.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :migrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_008_072_020

  @reconnect "The calendar server rejected the stored credentials. Please reconnect the calendar."

  defp reload(integration), do: Repo.get!(CalendarIntegrationSchema, integration.id)

  test "clears the text an unflagged integration's last failure left behind" do
    subscription =
      insert(:calendar_integration,
        provider: "ics_url",
        sync_error: "Calendar subscription sync failed (Postgrex.Error): ERROR 23505"
      )

    google =
      insert(:calendar_integration,
        provider: "google",
        sync_error: "Google integration failed during token refresh: :econnrefused (RETRYABLE)"
      )

    MigrationRunner.replay!(@version)

    assert reload(subscription).sync_error == nil
    assert reload(google).sync_error == nil
  end

  test "keeps the reason a flagged integration awaits reconnection for" do
    flagged =
      insert(:calendar_integration,
        provider: "caldav",
        needs_reauth: true,
        sync_error: @reconnect
      )

    MigrationRunner.replay!(@version)

    assert reload(flagged).sync_error == @reconnect
    assert reload(flagged).needs_reauth
  end
end
