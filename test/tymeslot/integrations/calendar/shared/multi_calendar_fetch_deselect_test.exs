defmodule Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetchDeselectTest do
  @moduledoc """
  Covers the de-selection side effect of `MultiCalendarFetch`: calendars that
  no longer exist on the provider (HTTP 404) are unselected on the integration
  so they are not fetched — and 404 — again on every availability check.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch

  defmodule NotFoundAPI do
    @spec list_events(any(), binary(), any(), any()) ::
            {:error, atom(), binary()} | {:ok, list()}
    def list_events(_integration, "deleted@example.com", _start_time, _end_time) do
      {:error, :not_found, "Calendar not found"}
    end

    def list_events(_integration, calendar_id, _start_time, _end_time) do
      {:ok, [%{"id" => "#{calendar_id}-1", "summary" => "Event"}]}
    end
  end

  test "de-selects a deleted calendar and returns events from the remaining ones" do
    integration =
      insert(:calendar_integration,
        provider: "outlook",
        calendar_list: [
          %{"id" => "work", "selected" => true, "name" => "Work"},
          %{"id" => "deleted@example.com", "selected" => true, "name" => "Deleted"}
        ]
      )

    start_time = DateTime.utc_now()
    end_time = DateTime.add(start_time, 3600, :second)

    assert {:ok, events} =
             MultiCalendarFetch.list_events_with_selection(
               integration,
               start_time,
               end_time,
               NotFoundAPI
             )

    assert Enum.map(events, & &1["id"]) == ["work-1"]

    {:ok, refreshed} = CalendarIntegrationQueries.get(integration.id)

    assert Enum.find(refreshed.calendar_list, &(&1.id == "deleted@example.com")).selected ==
             false

    assert Enum.find(refreshed.calendar_list, &(&1.id == "work")).selected == true
  end

  test "de-selects the calendar even when it was the only selected one" do
    integration =
      insert(:calendar_integration,
        provider: "outlook",
        calendar_list: [
          %{"id" => "deleted@example.com", "selected" => true, "name" => "Deleted"}
        ]
      )

    start_time = DateTime.utc_now()
    end_time = DateTime.add(start_time, 3600, :second)

    # The deleted calendar is confirmed-absent (404), not a hard failure, so
    # `failed` is empty here. With nothing else selected, this is a
    # known-empty busy set, not a failed fetch.
    assert {:ok, []} =
             MultiCalendarFetch.list_events_with_selection(
               integration,
               start_time,
               end_time,
               NotFoundAPI
             )

    {:ok, refreshed} = CalendarIntegrationQueries.get(integration.id)

    assert Enum.find(refreshed.calendar_list, &(&1.id == "deleted@example.com")).selected ==
             false
  end
end
