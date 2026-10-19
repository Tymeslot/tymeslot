defmodule Tymeslot.CalendarGrid.ProviderSeriesTimeZoneWriteTest do
  @moduledoc """
  A repeating event created from the grid on Google or Outlook is written as
  wall clocks in the organiser's zone. Google refuses a recurring event whose
  start names no zone ("Missing time zone definition for start time"), so the
  create failed outright; Outlook took it as a UTC series, which moves an hour
  against local time at every DST change.

  The write travels down to the HTTP client through each provider's own API
  module, so the assertions are on the request body the provider receives.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
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
    swap_env(:google_calendar_api_module, GoogleAPI)
    swap_env(:outlook_calendar_api_module, OutlookAPI)

    %{user: insert(:user)}
  end

  @scopes %{
    "google" => "https://www.googleapis.com/auth/calendar",
    "outlook" => "https://graph.microsoft.com/Calendars.ReadWrite"
  }

  defp insert_integration(user, provider) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      oauth_scope: Map.fetch!(@scopes, provider)
    )
  end

  # Answers the create with `reply` and sends the decoded request body back.
  defp capture_create(reply) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
      send(test_pid, {:body, if(is_binary(body), do: Jason.decode!(body), else: body)})
      {:ok, %Req.Response{status: 201, body: Jason.encode!(reply)}}
    end)
  end

  defp create(user, integration, calendar_id, start_at, timezone, rule) do
    assert {:ok, _result} =
             EventCreation.run_create_event(%{
               creating: %{
                 title: "Weekly sync",
                 integration_id: integration.id,
                 calendar_id: calendar_id,
                 attendees: [],
                 recurrence_rule: rule
               },
               user_id: user.id,
               start_at: start_at,
               end_at: DateTime.add(start_at, 30, :minute),
               timezone: timezone
             })

    assert_received {:body, body}
    body
  end

  # Monday 5 October 2026, 09:00 in Berlin (CEST, UTC+2).
  @berlin_start ~U[2026-10-05 07:00:00Z]

  test "a Google series names the organiser's zone", %{user: user} do
    integration = insert_integration(user, "google")

    capture_create(%{
      "id" => "gseries01",
      "iCalUID" => "gseries01@google.com",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "2026-10-05T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "end" => %{"dateTime" => "2026-10-05T09:30:00+02:00", "timeZone" => "Europe/Berlin"},
      "recurrence" => ["RRULE:FREQ=WEEKLY"]
    })

    body = create(user, integration, "primary", @berlin_start, "Europe/Berlin", "FREQ=WEEKLY")

    assert body["start"] == %{"dateTime" => "2026-10-05T09:00:00", "timeZone" => "Europe/Berlin"}
    assert body["end"] == %{"dateTime" => "2026-10-05T09:30:00", "timeZone" => "Europe/Berlin"}
    assert body["recurrence"] == ["RRULE:FREQ=WEEKLY"]
  end

  # 08:00 on Monday in Tokyo is 23:00 on Sunday in UTC: the range starts, and
  # a weekly pattern repeats, on the Monday.
  test "an Outlook series names the organiser's zone and starts on its local date", %{
    user: user
  } do
    integration = insert_integration(user, "outlook")
    tokyo_start = ~U[2026-10-04 23:00:00Z]

    capture_create(%{
      "id" => "oseries01",
      "iCalUId" => "oseries01-ical",
      "subject" => "Weekly sync",
      "start" => %{
        "dateTime" => "2026-10-05T08:00:00.0000000",
        "timeZone" => "Tokyo Standard Time"
      },
      "end" => %{"dateTime" => "2026-10-05T08:30:00.0000000", "timeZone" => "Tokyo Standard Time"}
    })

    body = create(user, integration, nil, tokyo_start, "Asia/Tokyo", "FREQ=WEEKLY")

    assert body["start"] == %{
             "dateTime" => "2026-10-05T08:00:00",
             "timeZone" => "Tokyo Standard Time"
           }

    assert body["end"] == %{
             "dateTime" => "2026-10-05T08:30:00",
             "timeZone" => "Tokyo Standard Time"
           }

    assert body["recurrence"]["range"]["startDate"] == "2026-10-05"
    assert body["recurrence"]["pattern"]["daysOfWeek"] == ["monday"]
  end

  # Graph does not list Europe/Madrid among the IANA names it accepts. The
  # series goes out under the Windows zone CLDR maps Madrid to.
  test "an Outlook series in a zone Graph does not list names a Windows zone", %{user: user} do
    integration = insert_integration(user, "outlook")

    capture_create(%{
      "id" => "oseries02",
      "iCalUId" => "oseries02-ical",
      "subject" => "Weekly sync",
      "start" => %{
        "dateTime" => "2026-10-05T09:00:00.0000000",
        "timeZone" => "Romance Standard Time"
      },
      "end" => %{
        "dateTime" => "2026-10-05T09:30:00.0000000",
        "timeZone" => "Romance Standard Time"
      }
    })

    body = create(user, integration, nil, @berlin_start, "Europe/Madrid", "FREQ=WEEKLY")

    assert body["start"] == %{
             "dateTime" => "2026-10-05T09:00:00",
             "timeZone" => "Romance Standard Time"
           }
  end

  test "a one-off keeps the UTC form on Google", %{user: user} do
    integration = insert_integration(user, "google")

    capture_create(%{
      "id" => "gsingle01",
      "iCalUID" => "gsingle01@google.com",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "2026-10-05T07:00:00Z"},
      "end" => %{"dateTime" => "2026-10-05T07:30:00Z"}
    })

    body = create(user, integration, "primary", @berlin_start, "Europe/Berlin", nil)

    refute Map.has_key?(body["start"], "timeZone")
  end
end
