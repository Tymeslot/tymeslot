defmodule Tymeslot.Migrations.CreateCalendarSeriesRulesTest do
  @moduledoc """
  `20261013083019_create_calendar_series_rules`: the new table, and the one
  full read it gives every existing Google and Outlook integration so the
  series they already hold fill in. Driven from `priv` with
  `MigrationRunner.rerun!/2`, which takes it down and back up.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :calendar
  @moduletag :migrations

  import Tymeslot.Factory

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_013_083_019

  test "gives Google and Outlook integrations one full read and leaves the others alone" do
    synced_at = ~U[2026-10-01 09:00:00Z]

    google = insert(:calendar_integration, provider: "google", google_sync_token: "token-1")

    outlook =
      insert(:calendar_integration,
        provider: "outlook",
        last_full_sync_at: synced_at,
        graph_delta_link: "https://graph.microsoft.com/delta?$deltatoken=1"
      )

    caldav = insert(:calendar_integration, provider: "caldav", last_full_sync_at: synced_at)

    MigrationRunner.rerun!(@version)

    assert Repo.reload!(google).google_sync_token == nil

    # The delta link is kept: the stale full-sync time alone makes the next
    # run bootstrap afresh, and nothing cached is deleted.
    outlook = Repo.reload!(outlook)
    assert outlook.last_full_sync_at == nil
    assert outlook.graph_delta_link == "https://graph.microsoft.com/delta?$deltatoken=1"

    assert Repo.reload!(caldav).last_full_sync_at == synced_at
  end

  test "creates a table whose rows go with their integration" do
    MigrationRunner.rerun!(@version)
    integration = insert(:calendar_integration, provider: "google")

    Repo.query!(
      """
      INSERT INTO calendar_series_rules
        (calendar_integration_id, provider_master_id, rule, fetched_at, inserted_at, updated_at)
      VALUES ($1, 'master-1', 'FREQ=WEEKLY', now(), now(), now())
      """,
      [integration.id]
    )

    # A test's own fixture, deleted to see the rows go with it.
    # excellent_migrations:safety-assured-for-next-line operation_delete
    Repo.delete!(integration)

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM calendar_series_rules")
  end
end
