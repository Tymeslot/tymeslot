defmodule Tymeslot.Integrations.Calendar.Outlook.ReminderSyncTest do
  @moduledoc """
  A reminder switched off in Outlook stays off in Tymeslot. Graph keeps the
  lead time of a reminder that was switched off, so a read that does not ask
  for `isReminderOn` turns every such event back into one with a reminder.

  The stub answers as Graph does: only the fields the request's `$select`
  names.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.EventNormaliser
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  @switched_off %{
    "id" => "AAMkOff",
    "iCalUId" => "ical-off",
    "subject" => "Reminder switched off",
    "start" => %{"dateTime" => "2026-11-10T09:00:00.0000000", "timeZone" => "UTC"},
    "end" => %{"dateTime" => "2026-11-10T10:00:00.0000000", "timeZone" => "UTC"},
    "isReminderOn" => false,
    "reminderMinutesBeforeStart" => 15
  }

  @context %{
    calendar_integration_id: 1,
    provider_calendar_id: "cal1",
    synced_at: ~U[2026-11-01 00:00:00Z]
  }

  defp selected(event, url) do
    case URI.decode_query(URI.parse(url).query || "")["$select"] do
      nil -> event
      select -> Map.take(event, String.split(select, ","))
    end
  end

  defp serve(event, wrap) do
    stub(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: Jason.encode!(wrap.(selected(event, url)))}}
    end)
  end

  defp reminders(raw) do
    {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
    event.reminders
  end

  setup do
    integration =
      insert(:calendar_integration,
        provider: "outlook",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

    %{integration: integration}
  end

  test "a calendar read keeps a switched-off reminder off", %{integration: integration} do
    serve(@switched_off, &%{"value" => [&1]})
    now = DateTime.utc_now()

    assert {:ok, [raw]} = CalendarAPI.list_events(integration, "cal1", now, now)
    assert reminders(raw) == []
  end

  test "a single-event read keeps a switched-off reminder off" do
    serve(@switched_off, & &1)

    assert {:ok, raw} = CalendarAPI.get_event_raw("valid_token", "AAMkOff")
    assert reminders(raw) == []
  end

  test "a single-event read keeps a reminder that is on" do
    serve(%{@switched_off | "isReminderOn" => true}, & &1)

    assert {:ok, raw} = CalendarAPI.get_event_raw("valid_token", "AAMkOff")
    assert reminders(raw) == [%{method: :popup, minutes_before: 15}]
  end
end
