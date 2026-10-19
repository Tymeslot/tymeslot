defmodule Tymeslot.Repo.Migrations.AddBlocksAvailabilityToCalendarListTest do
  @moduledoc """
  Every calendar blocked availability before the per-calendar choice existed,
  so the migration must write `true` into every stored entry without moving,
  dropping or rewriting anything else, and must never overwrite a choice an
  owner has already made.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :migrations

  import Tymeslot.Factory

  alias Tymeslot.Test.MigrationRunner

  @version 20_261_009_072_738

  # Writes `entries` as stored JSON, bypassing `CalendarEntry`, which would
  # add the key on the way in.
  defp integration_storing(entries) do
    integration = insert(:calendar_integration, provider: "caldav", calendar_list: [])

    Repo.query!("UPDATE calendar_integrations SET calendar_list = $1::jsonb[] WHERE id = $2", [
      entries,
      integration.id
    ])

    integration
  end

  defp stored(integration) do
    %{rows: [[list]]} =
      Repo.query!("SELECT calendar_list FROM calendar_integrations WHERE id = $1", [
        integration.id
      ])

    list
  end

  defp legacy_list do
    [
      %{"id" => "/cal/work/", "selected" => true, "read_only" => false},
      %{"id" => "/cal/shared/", "selected" => true, "read_only" => true},
      %{"id" => "/cal/old/", "selected" => false, "access_role" => "reader"}
    ]
  end

  test "makes every legacy entry block, selected or not" do
    integration = integration_storing(legacy_list())

    MigrationRunner.rerun!(@version)

    assert stored(integration) ==
             Enum.map(legacy_list(), &Map.put(&1, "blocks_availability", true))
  end

  test "leaves anything in the list that is not an entry as it is, run after run" do
    integration = integration_storing(["stray", 42, ["nested"], nil, %{"id" => "work"}])

    MigrationRunner.rerun!(@version)
    MigrationRunner.replay!(@version)

    assert stored(integration) ==
             ["stray", 42, ["nested"], nil, %{"id" => "work", "blocks_availability" => true}]

    MigrationRunner.down!(@version)

    assert stored(integration) == ["stray", 42, ["nested"], nil, %{"id" => "work"}]
  end

  test "leaves a row with no calendar list at all as it is" do
    integration = integration_storing([])

    Repo.query!("UPDATE calendar_integrations SET calendar_list = NULL WHERE id = $1", [
      integration.id
    ])

    MigrationRunner.rerun!(@version)

    assert stored(integration) == nil
  end

  test "keeps a show-only choice an owner already made" do
    integration =
      integration_storing([
        %{"id" => "holidays", "selected" => true, "blocks_availability" => false},
        %{"id" => "work", "selected" => true}
      ])

    # `up` alone: `down` would strip the choice first.
    MigrationRunner.replay!(@version)

    assert [%{"blocks_availability" => false}, %{"blocks_availability" => true}] =
             stored(integration)
  end

  test "leaves an integration with no calendar list as it is" do
    integration = integration_storing([])

    MigrationRunner.rerun!(@version)

    assert stored(integration) == []
  end

  test "a second run changes nothing" do
    integration = integration_storing(legacy_list())

    MigrationRunner.rerun!(@version)
    after_first = stored(integration)

    MigrationRunner.replay!(@version)

    assert stored(integration) == after_first

    assert %{num_rows: 0} =
             Repo.query!("""
             SELECT 1 FROM calendar_integrations, unnest(calendar_list) AS e(entry)
             WHERE NOT (e.entry ? 'blocks_availability')
             """)
  end

  test "down strips the key and nothing else" do
    integration = integration_storing(legacy_list())

    MigrationRunner.rerun!(@version)
    MigrationRunner.down!(@version)

    assert stored(integration) == legacy_list()
  end
end
