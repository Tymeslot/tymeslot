defmodule Tymeslot.Repo.Migrations.ClearReadOnlyOnExchangeCalendarsTest do
  @moduledoc """
  Exchange folders discovered before write support were pinned read-only, and
  nothing recomputes that flag on a sync. Without this repair an upgraded
  mailbox keeps refusing bookings, so what matters is that the migration
  reaches the rows that already exist and leaves every other provider's alone.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :migrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_903_105_822

  defp integration_with(provider, entries) do
    insert(:calendar_integration, provider: provider, calendar_list: entries)
  end

  defp reload(integration), do: Repo.get!(CalendarIntegrationSchema, integration.id)

  defp entry(attrs) do
    struct!(
      %CalendarEntry{id: "folder-1", name: "Calendar", selected: true, read_only: false},
      attrs
    )
  end

  test "makes an Exchange mailbox connected before write support writable again" do
    integration = integration_with("exchange", [entry(%{read_only: true})])

    MigrationRunner.replay!(@version)

    assert [%CalendarEntry{read_only: false}] = reload(integration).calendar_list
  end

  test "leaves every other field of the entry as it found it" do
    integration =
      integration_with("exchange", [
        entry(%{id: "AAMkAD==", name: "Team calendar", selected: true, read_only: true})
      ])

    MigrationRunner.replay!(@version)

    assert [restored] = reload(integration).calendar_list
    assert restored.id == "AAMkAD=="
    assert restored.name == "Team calendar"
    assert restored.selected == true
  end

  test "keeps the folders in the order they were stored" do
    # `Defaults.default_booking_calendar/2` falls back to the first eligible
    # entry, so a reshuffle would silently move which calendar bookings land
    # in.
    integration =
      integration_with("exchange", [
        entry(%{id: "first", read_only: true}),
        entry(%{id: "second", read_only: true}),
        entry(%{id: "third", read_only: true})
      ])

    MigrationRunner.replay!(@version)

    assert ["first", "second", "third"] = Enum.map(reload(integration).calendar_list, & &1.id)
  end

  test "leaves a read-only ICS subscription read-only" do
    # `read_only: true` is correct there and load-bearing: an ICS feed is a
    # one-way subscription with nothing to write back to.
    integration = integration_with("ics_url", [entry(%{read_only: true})])

    MigrationRunner.replay!(@version)

    assert [%CalendarEntry{read_only: true}] = reload(integration).calendar_list
  end

  test "leaves a CalDAV calendar the server itself called read-only alone" do
    integration = integration_with("caldav", [entry(%{read_only: true})])

    MigrationRunner.replay!(@version)

    assert [%CalendarEntry{read_only: true}] = reload(integration).calendar_list
  end

  test "does not disturb an Exchange integration that has no folders yet" do
    integration = integration_with("exchange", [])

    MigrationRunner.replay!(@version)

    assert reload(integration).calendar_list == []
  end
end
