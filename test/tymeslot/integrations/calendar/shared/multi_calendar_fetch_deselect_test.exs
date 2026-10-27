defmodule Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetchDeselectTest do
  @moduledoc """
  Covers the de-selection side effect of `MultiCalendarFetch`: calendars that
  no longer exist on the provider (HTTP 404) are unselected on the integration
  so they are not fetched — and 404 — again on every availability check.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleCalendarAPI
  alias Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

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

  test "still answers when the integration is removed before the de-selection is written" do
    integration =
      insert(:calendar_integration,
        provider: "outlook",
        calendar_list: [
          %{"id" => "work", "selected" => true, "name" => "Work"},
          %{"id" => "deleted@example.com", "selected" => true, "name" => "Deleted"}
        ]
      )

    # The owner disconnects the integration while an availability read that
    # started from it is still on the network.
    Repo.delete!(integration)
    LogCapture.attach(logger_level: :info)

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

    # A race with nothing left to fix, so not reported as an error.
    event = LogCapture.await_log("Integration gone before missing calendars")
    assert event.level == :info
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

  # Through the real Google client, with only HTTP stubbed: a holiday
  # calendar's id carries a `#`, and a request that loses the rest of the id
  # to a URL fragment reaches another calendar, which answers 404 and gets the
  # holiday calendar de-selected for good.
  test "reads a selected Google holiday calendar and keeps it selected" do
    holiday_id = "en.uk#holiday@group.v.calendar.google.com"

    integration =
      insert(:calendar_integration,
        provider: "google",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        calendar_list: [%{"id" => holiday_id, "selected" => true, "name" => "Holidays"}]
      )

    expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
      case URI.parse(url).path do
        "/calendar/v3/calendars/en.uk%23holiday%40group.v.calendar.google.com/events" ->
          body = %{"items" => [%{"id" => "bank-holiday", "summary" => "Bank holiday"}]}
          {:ok, %Req.Response{status: 200, body: Jason.encode!(body)}}

        _another_calendar ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end)

    start_time = DateTime.utc_now()
    end_time = DateTime.add(start_time, 3600, :second)

    assert {:ok, [%{"id" => "bank-holiday"}]} =
             MultiCalendarFetch.list_events_with_selection(
               integration,
               start_time,
               end_time,
               GoogleCalendarAPI
             )

    {:ok, refreshed} = CalendarIntegrationQueries.get(integration.id)
    assert Enum.find(refreshed.calendar_list, &(&1.id == holiday_id)).selected == true
  end
end
