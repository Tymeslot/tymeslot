defmodule Tymeslot.CalendarGrid.EventEditProviderSplitNotOrganiserTest do
  @moduledoc """
  A "this and following" edit of an Outlook recurring series the account was
  only invited to, never organises.

  Without a guard, the split would copy the master's own attendees into a
  new series created under this account, so Graph would invite everyone on
  it afresh to a meeting the account now organises, and leave the real
  organiser off it (see `Tymeslot.Integrations.Calendar.Outlook.Provider`).
  The split must be refused before the tail is created.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  setup do
    swap_env(:calendar_module, Operations)
    swap_env(:outlook_calendar_api_module, OutlookAPI)

    %{user: insert(:user)}
  end

  @zone "W. Europe Standard Time"

  # A weekly Monday series the account was only invited to: `isOrganizer` is
  # false, as Graph marks an event on the account's calendar that someone
  # else organises.
  @master %{
    "id" => "master-1",
    "iCalUId" => "040000008200E00074C5B7101A82E008",
    "type" => "seriesMaster",
    "subject" => "Weekly sync",
    "isAllDay" => false,
    "isOnlineMeeting" => false,
    "isOrganizer" => false,
    "organizer" => %{"emailAddress" => %{"address" => "owner@example.com"}},
    "attendees" => [
      %{
        "type" => "required",
        "status" => %{"response" => "accepted", "time" => "2026-05-21T10:00:00Z"},
        "emailAddress" => %{"address" => "guest@example.com", "name" => "Guest"}
      }
    ],
    "start" => %{"dateTime" => "2026-06-01T07:00:00.0000000", "timeZone" => "UTC"},
    "end" => %{"dateTime" => "2026-06-01T08:00:00.0000000", "timeZone" => "UTC"},
    "originalStartTimeZone" => @zone,
    "recurrence" => %{
      "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["monday"]},
      "range" => %{
        "type" => "numbered",
        "startDate" => "2026-06-01",
        "numberOfOccurrences" => 30
      }
    }
  }

  defp insert_integration(user) do
    insert(:calendar_integration,
      user: user,
      provider: "outlook",
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite"
    )
  end

  defp insert_occurrence(integration) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "outlook",
      provider_calendar_id: "primary",
      summary: "Weekly sync",
      all_day: false,
      timezone: "Europe/Berlin",
      recurring_event_id: "master-1",
      provider_metadata: %{"type" => "occurrence"},
      sync_state: "synced",
      uid: "weekly_20261102T080000Z",
      provider_event_id: "master-1_20261102T080000Z",
      start_at: ~U[2026-11-02 08:00:00.000000Z],
      end_at: ~U[2026-11-02 09:00:00.000000Z]
    )
  end

  # Answers every request through `answer` and records it, in order.
  defp serve(answer) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})

      case answer.(method, url) do
        {status, nil} -> {:ok, %Req.Response{status: status, body: ""}}
        {status, reply} -> {:ok, %Req.Response{status: status, body: Jason.encode!(reply)}}
      end
    end)
  end

  defp requests do
    receive do
      {:request, method, url, body} -> [{method, url, body} | requests()]
    after
      0 -> []
    end
  end

  defp methods(requests), do: Enum.map(requests, &elem(&1, 0))

  test "a following-split of a series the account was only invited to is refused before the tail is created",
       %{user: user} do
    integration = insert_integration(user)
    occurrence = insert_occurrence(integration)

    serve(fn
      :get, url ->
        if String.contains?(url, "/master-1/calendar"),
          do: {200, %{"id" => "team-calendar"}},
          else: {200, @master}

      :post, _url ->
        flunk("the tail must not be created for a series the account does not organise")

      :patch, _url ->
        flunk("the master must not be patched for a series the account does not organise")

      :delete, _url ->
        flunk("nothing must be deleted for a series the account does not organise")
    end)

    assert {:error, %{reason: :not_organiser}} =
             CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
               recurrence_scope: :following
             )

    assert methods(requests()) == [:get]

    assert {:ok, %{summary: "Weekly sync"}} =
             ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)
  end
end
