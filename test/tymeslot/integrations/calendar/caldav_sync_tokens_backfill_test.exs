defmodule Tymeslot.Integrations.Calendar.CaldavSyncTokensBackfillTest do
  @moduledoc """
  Drives `20260922172133_move_caldav_sync_token_to_per_path_map` itself: `up`
  carries each integration's single sync token across as its primary calendar
  path's entry, so the first sync after deploy resumes rather than rebuilding
  from scratch, and `down` restores the primary path's token.

  The migration module is loaded from `priv` and run through
  `Ecto.Migrator`; see `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :calendar

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_922_172_133

  test "up keys the old token by the primary path, and down restores it" do
    primary = "/calendars/alice/default/"
    extra = "/calendars/alice/shared/"

    with_token =
      insert(:calendar_integration,
        provider: "caldav",
        calendar_paths: [primary, extra],
        caldav_sync_tokens: %{primary => "token-primary", extra => "token-extra"}
      )

    without_token = insert(:calendar_integration, provider: "caldav", calendar_paths: [primary])

    # A token with no path to key it under has nothing to resume; it must not
    # become a `null`-keyed entry, which Postgres would reject outright.
    without_paths =
      insert(:calendar_integration,
        provider: "caldav",
        calendar_paths: [],
        caldav_sync_tokens: %{primary => "orphan"}
      )

    MigrationRunner.down!(@version)

    assert old_token(with_token) == "token-primary"
    assert old_token(without_token) == nil
    assert old_token(without_paths) == nil

    Repo.query!("UPDATE calendar_integrations SET caldav_sync_token = 'orphan' WHERE id = $1", [
      without_paths.id
    ])

    MigrationRunner.up!(@version)

    assert Repo.reload!(with_token).caldav_sync_tokens == %{primary => "token-primary"}
    assert Repo.reload!(without_token).caldav_sync_tokens == nil
    assert Repo.reload!(without_paths).caldav_sync_tokens == nil
  end

  # `down` drops `caldav_sync_tokens`, so a full-row reload would ask for a
  # column that no longer exists.
  defp old_token(integration) do
    %{rows: [[token]]} =
      Repo.query!("SELECT caldav_sync_token FROM calendar_integrations WHERE id = $1", [
        integration.id
      ])

    token
  end
end
