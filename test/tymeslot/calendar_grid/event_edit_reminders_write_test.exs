defmodule Tymeslot.CalendarGrid.EventEditRemindersWriteTest do
  @moduledoc """
  What a grid edit that is not about reminders puts on the wire for the
  event's reminders, per provider.

  The `:calendar_module` seam (and the Google and Outlook API modules) are
  pointed back at the runtime modules, so only the HTTP client is mocked and
  the body the provider receives is the thing under test.

  The sync never reads a CalDAV event's VALARMs, so the cached row says
  `reminders: []` whatever the server holds, and the patcher replaces every
  VALARM whenever the payload carries `:reminders`. A rename that sent the
  cached list used to delete every alarm on the organiser's server, silently.
  Google and Outlook read their reminders back on sync and treat a missing
  key as a reset, so their writes keep restating the cached list.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  # An alarm set in another client: a day before, which Tymeslot's builder
  # would never write (it emits minutes), so a survivor is unmistakably the
  # stored one.
  @stored_alarm [
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    "TRIGGER:-P1D",
    "DESCRIPTION:Bring the slides",
    "END:VALARM"
  ]

  @synced_ical """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  PRODID:-//Apple Inc.//macOS 15.0//EN\r
  BEGIN:VEVENT\r
  UID:board-meeting\r
  DTSTAMP:20260901T090000Z\r
  DTSTART:20260910T090000Z\r
  DTEND:20260910T100000Z\r
  SUMMARY:Board meeting\r
  #{Enum.join(@stored_alarm, "\r\n")}\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  @caldav_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/cal/"],
    provider: :caldav
  }

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  defp oauth_integration(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      oauth_scope: scope
    )
  end

  defp capture_put do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, fn _url, body, _headers, _opts ->
      send(test_pid, {:put, body})
      {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
    end)
  end

  defp put_lines do
    assert_received {:put, body}
    LineFolder.unfold_lines(body)
  end

  defp contains_block?(lines, block),
    do: Enum.any?(Enum.chunk_every(lines, length(block), 1, :discard), &(&1 == block))

  setup do
    swap_env(:calendar_module, Operations)
    %{user: insert(:user)}
  end

  describe "editing a synced CalDAV event whose document has an alarm" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      # As the sync stores it: the document carries the alarm, the
      # `reminders` column does not.
      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "board-meeting",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/board-meeting.ics",
          summary: "Board meeting",
          start_at: ~U[2026-09-10 09:00:00.000000Z],
          end_at: ~U[2026-09-10 10:00:00.000000Z],
          all_day: false,
          timezone: "UTC",
          reminders: [],
          etag: "\"etag-1\"",
          raw_ical: @synced_ical,
          sync_state: "synced"
        )

      %{integration: integration, event: event}
    end

    test "a rename keeps the stored VALARM", %{user: user, event: event} do
      capture_put()

      assert {:ok, _updated} = EventEdit.update_event(user.id, event, %{summary: "Renamed"})

      lines = put_lines()
      assert "SUMMARY:Renamed" in lines
      assert contains_block?(lines, @stored_alarm)
    end

    test "a retime keeps the stored VALARM", %{user: user, event: event} do
      capture_put()

      assert {:ok, _updated} =
               EventEdit.update_event(user.id, event, %{
                 start_at: ~U[2026-09-10 11:00:00Z],
                 end_at: ~U[2026-09-10 12:00:00Z]
               })

      lines = put_lines()
      assert "DTSTART:20260910T110000Z" in lines
      assert contains_block?(lines, @stored_alarm)
    end

    test "an edit of the reminders replaces the stored VALARM with the new one", %{
      user: user,
      event: event
    } do
      capture_put()

      assert {:ok, _updated} =
               EventEdit.update_event(user.id, event, %{
                 reminders: [%{method: :popup, minutes_before: 10}]
               })

      lines = put_lines()
      assert "TRIGGER:-PT10M" in lines
      refute "TRIGGER:-P1D" in lines
      assert Enum.count(lines, &(&1 == "BEGIN:VALARM")) == 1
    end

    test "a rename queued for replay keeps the stored VALARM when it is replayed", %{
      user: user,
      integration: integration,
      event: event
    } do
      assert {:ok, _updated} = EventEdit.queue_for_retry(user.id, event, %{summary: "Renamed"})
      assert Repo.reload!(event).sync_state == "locally_modified"

      capture_put()

      assert :ok = OfflineQueue.flush(integration, @caldav_client)

      lines = put_lines()
      assert "SUMMARY:Renamed" in lines
      assert contains_block?(lines, @stored_alarm)
      assert Repo.reload!(event).sync_state == "synced"
    end
  end

  describe "editing a synced Google event with reminder overrides" do
    setup %{user: user} do
      swap_env(:google_calendar_api_module, GoogleAPI)

      integration =
        oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "boardmeeting",
          provider: "google",
          provider_calendar_id: "primary",
          provider_event_id: "boardmeeting",
          summary: "Board meeting",
          start_at: ~U[2026-09-10 09:00:00.000000Z],
          end_at: ~U[2026-09-10 10:00:00.000000Z],
          all_day: false,
          reminders: [%{"method" => "email", "minutes_before" => 1440}],
          sync_state: "synced"
        )

      %{event: event}
    end

    # `events.update` is a `PUT`: a body without `reminders` puts the event
    # back on the calendar's defaults, so the synced overrides must be sent.
    test "a rename restates the synced overrides", %{user: user, event: event} do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :put, _url, body, _headers, _opts ->
        send(test_pid, {:google_put, body})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "boardmeeting"})}}
      end)

      assert {:ok, _updated} = EventEdit.update_event(user.id, event, %{summary: "Renamed"})

      assert_received {:google_put, body}

      assert Jason.decode!(body)["reminders"] == %{
               "useDefault" => false,
               "overrides" => [%{"method" => "email", "minutes" => 1440}]
             }
    end
  end

  describe "editing a synced Outlook event with a reminder" do
    setup %{user: user} do
      swap_env(:outlook_calendar_api_module, OutlookAPI)

      integration =
        oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "040000008200E00074C5B7101A82E00B",
          provider: "outlook",
          provider_calendar_id: "primary",
          provider_event_id: "AAMkBoard",
          summary: "Board meeting",
          start_at: ~U[2026-11-10 09:00:00.000000Z],
          end_at: ~U[2026-11-10 10:00:00.000000Z],
          all_day: false,
          timezone: "Etc/UTC",
          reminders: [%{"method" => "popup", "minutes_before" => 30}],
          sync_state: "synced"
        )

      %{event: event}
    end

    # The Graph mapper reads a missing `:reminders` as "no reminder" and sends
    # `isReminderOn: false`, so the synced lead time must be sent.
    test "a rename keeps the reminder on with its lead time", %{user: user, event: event} do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :patch, _url, body, _headers, _opts ->
        send(test_pid, {:graph_patch, body})

        answer = %{
          "id" => "AAMkBoard",
          "iCalUId" => "040000008200E00074C5B7101A82E00B",
          "type" => "singleInstance",
          "subject" => "Renamed",
          "start" => %{"dateTime" => "2026-11-10T09:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2026-11-10T10:00:00.0000000", "timeZone" => "UTC"}
        }

        {:ok, %Req.Response{status: 200, body: Jason.encode!(answer)}}
      end)

      assert {:ok, _updated} = EventEdit.update_event(user.id, event, %{summary: "Renamed"})

      assert_received {:graph_patch, body}
      sent = Jason.decode!(body)
      assert sent["isReminderOn"] == true
      assert sent["reminderMinutesBeforeStart"] == 30
    end
  end
end
