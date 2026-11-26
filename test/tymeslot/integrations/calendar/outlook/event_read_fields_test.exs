defmodule Tymeslot.Integrations.Calendar.Outlook.EventReadFieldsTest do
  @moduledoc """
  The reads that select their fields (the calendar read, and the single-event
  read the change-notification sync caches from) cache the same event as the
  delta sync, which selects nothing. A field left out of a `$select` is cached
  as absent until the next delta sync puts it back.

  The stub answers as Graph does: only the fields `$select` names, and the
  body as HTML unless the `Prefer` header asks for text.
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

  @graph_event %{
    "id" => "AAMkFull",
    "iCalUId" => "ical-full",
    "subject" => "Quarterly review",
    "start" => %{"dateTime" => "2026-11-10T09:00:00.0000000", "timeZone" => "UTC"},
    "end" => %{"dateTime" => "2026-11-10T10:00:00.0000000", "timeZone" => "UTC"},
    "originalStartTimeZone" => "W. Europe Standard Time",
    "isAllDay" => false,
    "location" => %{"displayName" => "Room 4"},
    "sensitivity" => "private",
    "showAs" => "busy",
    "isCancelled" => false,
    "responseStatus" => %{"response" => "declined"},
    "organizer" => %{"emailAddress" => %{"address" => "ada@example.com", "name" => "Ada"}},
    "attendees" => [
      %{
        "type" => "required",
        "emailAddress" => %{"address" => "grace@example.com", "name" => "Grace"},
        "status" => %{"response" => "accepted"}
      }
    ],
    "isReminderOn" => true,
    "reminderMinutesBeforeStart" => 15,
    "type" => "singleInstance"
  }

  @text_body %{"contentType" => "text", "content" => "Agenda: budget"}
  @html_body %{"contentType" => "html", "content" => "<p>Agenda: budget</p>"}

  @context %{
    calendar_integration_id: 1,
    provider_calendar_id: "cal1",
    synced_at: ~U[2026-11-01 00:00:00Z]
  }

  defp as_graph_answers(url, headers) do
    text_body? =
      Enum.any?(headers, fn {name, value} ->
        name == "Prefer" and value =~ ~s(outlook.body-content-type="text")
      end)

    event = Map.put(@graph_event, "body", if(text_body?, do: @text_body, else: @html_body))

    case URI.decode_query(URI.parse(url).query || "")["$select"] do
      nil -> event
      select -> Map.take(event, String.split(select, ","))
    end
  end

  defp serve(wrap) do
    stub(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, headers, _opts ->
      {:ok,
       %Req.Response{status: 200, body: Jason.encode!(wrap.(as_graph_answers(url, headers)))}}
    end)
  end

  defp normalise(raw) do
    {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
    event
  end

  # What the delta sync caches: every field, the body as text.
  defp delta_cached, do: normalise(Map.put(@graph_event, "body", @text_body))

  test "a calendar read caches every field the delta sync caches" do
    integration =
      insert(:calendar_integration,
        provider: "outlook",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

    serve(&%{"value" => [&1]})
    now = DateTime.utc_now()

    assert {:ok, [raw]} = CalendarAPI.list_events(integration, "cal1", now, now)
    assert normalise(raw) == delta_cached()
  end

  test "a single-event read caches every field the delta sync caches" do
    serve(& &1)

    assert {:ok, raw} = CalendarAPI.get_event_raw("valid_token", "AAMkFull")
    assert normalise(raw).description == "Agenda: budget"
    assert normalise(raw) == delta_cached()
  end
end
