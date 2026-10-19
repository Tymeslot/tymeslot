defmodule Tymeslot.CalendarGrid.OccurrenceWriteRuleTest do
  @moduledoc """
  Edits of a Google or Outlook series made from a cached occurrence that
  carries its series' rule, down to the HTTP client.

  Google and Outlook address an occurrence by its own instance id, so a
  write of that one occurrence must say nothing about recurrence: a rule
  sent to an instance asks the provider to make that one occurrence a series
  of its own. A new rule for the whole series replaces only the master's
  rule, and keeps the dates the series excludes or adds.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup do
    put_module(:calendar_module, Operations)
    put_module(:google_calendar_api_module, GoogleAPI)
    put_module(:outlook_calendar_api_module, OutlookAPI)

    %{user: insert(:user)}
  end

  test "a Google instance update carries no recurrence", %{user: user} do
    integration = integration(user, "google", "https://www.googleapis.com/auth/calendar")

    event =
      occurrence(integration, "google", %{
        uid: "master1@google.com_20261019T070000Z",
        provider_event_id: "master1_20261019T070000Z",
        recurring_event_id: "master1"
      })

    serve(%{"id" => "master1_20261019T070000Z", "status" => "confirmed"})

    assert {:ok, _updated} =
             CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
               recurrence_scope: :this_only
             )

    assert [body] = written_bodies("master1_20261019T070000Z")
    assert body["summary"] == "Renamed"
    refute Map.has_key?(body, "recurrence")
  end

  test "an Outlook occurrence update carries no recurrence", %{user: user} do
    integration = integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

    event =
      occurrence(integration, "outlook", %{
        uid: "040000008200E00074C5B7101A82E008-occurrence",
        provider_event_id: "AAMkOccurrence",
        recurring_event_id: "AAMkMaster"
      })

    serve(%{"id" => "AAMkOccurrence", "type" => "occurrence"})

    assert {:ok, _updated} =
             CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
               recurrence_scope: :this_only
             )

    assert [body] = written_bodies("AAMkOccurrence")
    assert body["subject"] == "Renamed"
    refute Map.has_key?(body, "recurrence")
  end

  test "a new rule for a whole Google series keeps the dates its master excludes", %{
    user: user
  } do
    integration = integration(user, "google", "https://www.googleapis.com/auth/calendar")

    event =
      occurrence(integration, "google", %{
        uid: "master1@google.com_20261019T070000Z",
        provider_event_id: "master1_20261019T070000Z",
        recurring_event_id: "master1"
      })

    master = %{
      "id" => "master1",
      "status" => "confirmed",
      "start" => %{"dateTime" => "2026-10-05T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "end" => %{"dateTime" => "2026-10-05T09:30:00+02:00", "timeZone" => "Europe/Berlin"},
      "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO", "EXDATE;TZID=Europe/Berlin:20261012T090000"]
    }

    serve(master)

    assert {:ok, _updated} =
             CalendarGrid.update_event(
               user.id,
               event,
               %{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=10"},
               recurrence_scope: :all
             )

    assert [body] = written_bodies("master1")

    assert body["recurrence"] == [
             "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10",
             "EXDATE;TZID=Europe/Berlin:20261012T090000"
           ]
  end

  defp put_module(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  defp integration(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      oauth_scope: scope
    )
  end

  # A cached occurrence stamped with its series' rule and zone, as the sync
  # caches it.
  defp occurrence(integration, provider, attrs) do
    insert(
      :provider_calendar_event,
      Map.merge(
        %{
          calendar_integration: integration,
          provider: provider,
          provider_calendar_id: "team-calendar",
          summary: "Weekly standup",
          all_day: false,
          start_at: ~U[2026-10-19 07:00:00.000000Z],
          end_at: ~U[2026-10-19 07:30:00.000000Z],
          timezone: "Europe/Berlin",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
          sync_state: "synced"
        },
        attrs
      )
    )
  end

  # Answers every request with `reply` and records it.
  defp serve(reply) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})
      {:ok, %Req.Response{status: 200, body: Jason.encode!(reply)}}
    end)
  end

  # The decoded bodies of the writes made to the resource `id`.
  defp written_bodies(id) do
    receive do
      {:request, method, url, body} when method in [:put, :patch] ->
        if String.contains?(url, id),
          do: [Jason.decode!(body) | written_bodies(id)],
          else: written_bodies(id)

      {:request, _method, _url, _body} ->
        written_bodies(id)
    after
      0 -> []
    end
  end
end
