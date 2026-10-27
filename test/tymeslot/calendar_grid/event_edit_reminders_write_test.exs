defmodule Tymeslot.CalendarGrid.EventEditRemindersWriteTest do
  @moduledoc """
  What a grid edit that is not about reminders puts on the wire for the
  event's reminders, per provider.

  The `:calendar_module` seam (and the Google and Outlook API modules) are
  pointed back at the runtime modules, so only the HTTP client is mocked and
  the body the provider receives is the thing under test.

  The patcher replaces every VALARM whenever the payload carries
  `:reminders`. A rename that sent the cached list used to delete every alarm
  on the organiser's server, silently, when the row said `reminders: []` (as
  every row did before the sync read VALARMs); one that sent the list the
  sync now reads would rebuild each alarm and lose what a reminder cannot
  hold. So a CalDAV write carries reminders only when the edit changes them.
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
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
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

  # Flushes the offline queue and answers the lines of the document it wrote.
  defp replayed_lines(integration) do
    capture_put()
    assert :ok = OfflineQueue.flush(integration, @caldav_client)
    put_lines()
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

      lines = replayed_lines(integration)
      assert "SUMMARY:Renamed" in lines
      assert contains_block?(lines, @stored_alarm)
      assert Repo.reload!(event).sync_state == "synced"
    end
  end

  describe "editing a CalDAV event whose alarms the sync read into reminders" do
    # Alarms as clients write them, with what a reminder cannot hold: the
    # recipient of an email alarm, Apple's alarm id and acknowledgement. A
    # VALARM rebuilt from the cached reminders would lose all of it.
    @email_alarm [
      "BEGIN:VALARM",
      "ACTION:EMAIL",
      "TRIGGER:-PT30M",
      "SUMMARY:Board meeting soon",
      "DESCRIPTION:Bring the slides",
      "ATTENDEE:mailto:host@example.com",
      "END:VALARM"
    ]

    @display_alarm [
      "BEGIN:VALARM",
      "X-WR-ALARMUID:5E8A1C2B-0D4F-4E7A-9B1C-2F3D4E5F6A7B",
      "ACTION:DISPLAY",
      "TRIGGER:-P1D",
      "DESCRIPTION:Reminder",
      "ACKNOWLEDGED:20260909T090000Z",
      "END:VALARM"
    ]

    # An alarm no reminder can express, so the sync reads nothing from it.
    @end_alarm [
      "BEGIN:VALARM",
      "ACTION:DISPLAY",
      "TRIGGER;RELATED=END:-PT5M",
      "DESCRIPTION:Wrap up",
      "END:VALARM"
    ]

    @read_ical """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Apple Inc.//macOS 15.0//EN\r
    BEGIN:VEVENT\r
    UID:read-alarms\r
    DTSTAMP:20260901T090000Z\r
    DTSTART:20260910T090000Z\r
    DTEND:20260910T100000Z\r
    SUMMARY:Board meeting\r
    #{Enum.join(@email_alarm, "\r\n")}\r
    #{Enum.join(@display_alarm, "\r\n")}\r
    #{Enum.join(@end_alarm, "\r\n")}\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    @read_reminders [
      %{method: :email, minutes_before: 30},
      %{method: :popup, minutes_before: 1440}
    ]

    setup %{user: user} do
      # The row as the sync now caches it: the reminders it read from the
      # document's alarms, beside the document itself.
      assert ICalNormaliser.document_reminders(@read_ical) == {:ok, @read_reminders}

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "read-alarms",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/read-alarms.ics",
          summary: "Board meeting",
          start_at: ~U[2026-09-10 09:00:00.000000Z],
          end_at: ~U[2026-09-10 10:00:00.000000Z],
          all_day: false,
          timezone: "UTC",
          reminders: @read_reminders,
          etag: "\"etag-1\"",
          raw_ical: @read_ical,
          sync_state: "synced"
        )

      %{integration: integration, event: event}
    end

    test "a rename leaves each alarm exactly as the server wrote it", %{user: user, event: event} do
      capture_put()

      assert {:ok, _updated} = EventEdit.update_event(user.id, event, %{summary: "Renamed"})

      lines = put_lines()
      assert "SUMMARY:Renamed" in lines
      assert contains_block?(lines, @email_alarm)
      assert contains_block?(lines, @display_alarm)
    end

    test "a replayed rename leaves each alarm exactly as the server wrote it", %{
      user: user,
      integration: integration,
      event: event
    } do
      assert {:ok, _updated} = EventEdit.queue_for_retry(user.id, event, %{summary: "Renamed"})
      lines = replayed_lines(integration)
      assert "SUMMARY:Renamed" in lines
      assert contains_block?(lines, @email_alarm)
      assert contains_block?(lines, @display_alarm)
    end

    test "a replayed edit of the reminders writes the new ones", %{
      user: user,
      integration: integration,
      event: event
    } do
      assert {:ok, _updated} =
               EventEdit.queue_for_retry(user.id, event, %{
                 reminders: [%{method: :popup, minutes_before: 10}]
               })

      lines = replayed_lines(integration)
      assert "TRIGGER:-PT10M" in lines
      refute contains_block?(lines, @email_alarm)
      refute contains_block?(lines, @display_alarm)
      assert contains_block?(lines, @end_alarm)
      assert Enum.count(lines, &(&1 == "BEGIN:VALARM")) == 2
    end

    test "a replayed removal of every reminder removes their alarms alone", %{
      user: user,
      integration: integration,
      event: event
    } do
      assert {:ok, _updated} = EventEdit.queue_for_retry(user.id, event, %{reminders: []})
      lines = replayed_lines(integration)
      refute contains_block?(lines, @email_alarm)
      refute contains_block?(lines, @display_alarm)
      assert contains_block?(lines, @end_alarm)
      assert Enum.count(lines, &(&1 == "BEGIN:VALARM")) == 1

      row = Repo.reload!(event)
      assert row.sync_state == "synced"
      refute row.sync_reminders_changed
    end

    test "a removal of every reminder is still replayed after a rename queued behind it", %{
      user: user,
      integration: integration,
      event: event
    } do
      assert {:ok, removed} = EventEdit.queue_for_retry(user.id, event, %{reminders: []})
      assert {:ok, _renamed} = EventEdit.queue_for_retry(user.id, removed, %{summary: "Renamed"})
      lines = replayed_lines(integration)
      assert "SUMMARY:Renamed" in lines
      refute contains_block?(lines, @email_alarm)
      refute contains_block?(lines, @display_alarm)
      assert contains_block?(lines, @end_alarm)
    end

    test "adding a reminder keeps every stored alarm exactly as the server wrote it", %{
      user: user,
      event: event
    } do
      capture_put()

      assert {:ok, _updated} =
               EventEdit.update_event(user.id, event, %{
                 reminders: @read_reminders ++ [%{method: :popup, minutes_before: 10}]
               })

      lines = put_lines()
      assert contains_block?(lines, @email_alarm)
      assert contains_block?(lines, @display_alarm)
      assert contains_block?(lines, @end_alarm)
      assert "TRIGGER:-PT10M" in lines
      assert Enum.count(lines, &(&1 == "BEGIN:VALARM")) == 4
    end

    test "removing the pop-up reminder removes its alarm alone", %{user: user, event: event} do
      capture_put()

      assert {:ok, _updated} =
               EventEdit.update_event(user.id, event, %{
                 reminders: [%{method: :email, minutes_before: 30}]
               })

      lines = put_lines()
      refute contains_block?(lines, @display_alarm)
      assert contains_block?(lines, @email_alarm)
      assert contains_block?(lines, @end_alarm)
      assert Enum.count(lines, &(&1 == "BEGIN:VALARM")) == 2
    end

    test "moving the email alert keeps it addressed to the recipient the client chose", %{
      user: user,
      event: event
    } do
      capture_put()

      assert {:ok, _updated} =
               EventEdit.update_event(user.id, event, %{
                 reminders: [%{method: :email, minutes_before: 60}]
               })

      assert contains_block?(put_lines(), [
               "BEGIN:VALARM",
               "TRIGGER:-PT60M",
               "ACTION:EMAIL",
               "SUMMARY:Board meeting",
               "DESCRIPTION:Reminder",
               "ATTENDEE:mailto:host@example.com",
               "END:VALARM"
             ])
    end
  end

  describe "replaying an edit of a CalDAV series with an edited occurrence" do
    # A series' resource holds the master and one VEVENT per occurrence edited
    # on its own, and the row stores the whole resource. The override carries
    # an alarm of its own, so the document as a whole has no single list of
    # reminders; only the master's alarms are the ones a patch replaces.
    #
    # The master repeats by RDATE, which the sync does not model, so its row
    # reads as a single event and the queue replays it (a row the sync knows
    # to be a series is refused before any replay).
    @override_alarm [
      "BEGIN:VALARM",
      "ACTION:DISPLAY",
      "TRIGGER;RELATED=END:PT5M",
      "DESCRIPTION:Wrap up",
      "END:VALARM"
    ]

    @series_ical """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Apple Inc.//macOS 15.0//EN\r
    BEGIN:VEVENT\r
    UID:weekly-board\r
    DTSTAMP:20260901T090000Z\r
    DTSTART:20260910T090000Z\r
    DTEND:20260910T100000Z\r
    RDATE:20260917T090000Z,20260924T090000Z\r
    SUMMARY:Board meeting\r
    #{Enum.join(@email_alarm, "\r\n")}\r
    #{Enum.join(@display_alarm, "\r\n")}\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:weekly-board\r
    RECURRENCE-ID:20260917T090000Z\r
    DTSTAMP:20260901T090000Z\r
    DTSTART:20260917T110000Z\r
    DTEND:20260917T120000Z\r
    SUMMARY:Board meeting (moved)\r
    #{Enum.join(@override_alarm, "\r\n")}\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    setup %{user: user} do
      # The master's reminders, which the sync caches on the series' row.
      assert ICalNormaliser.document_reminders(@series_ical) == {:ok, @read_reminders}

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "weekly-board",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/weekly-board.ics",
          summary: "Board meeting",
          start_at: ~U[2026-09-10 09:00:00.000000Z],
          end_at: ~U[2026-09-10 10:00:00.000000Z],
          all_day: false,
          timezone: "UTC",
          reminders: @read_reminders,
          etag: "\"etag-1\"",
          raw_ical: @series_ical,
          sync_state: "synced"
        )

      %{integration: integration, event: event}
    end

    test "a replayed rename leaves every alarm exactly as the server wrote it", %{
      user: user,
      integration: integration,
      event: event
    } do
      assert {:ok, _updated} = EventEdit.queue_for_retry(user.id, event, %{summary: "Renamed"})
      lines = replayed_lines(integration)
      assert "SUMMARY:Renamed" in lines
      assert contains_block?(lines, @email_alarm)
      assert contains_block?(lines, @display_alarm)
      assert contains_block?(lines, @override_alarm)
      assert Enum.count(lines, &(&1 == "BEGIN:VALARM")) == 3
    end

    test "a replayed edit of the reminders rewrites the master's alarms alone", %{
      user: user,
      integration: integration,
      event: event
    } do
      assert {:ok, _updated} =
               EventEdit.queue_for_retry(user.id, event, %{
                 reminders: [%{method: :popup, minutes_before: 10}]
               })

      lines = replayed_lines(integration)
      assert "TRIGGER:-PT10M" in lines
      refute contains_block?(lines, @email_alarm)
      refute contains_block?(lines, @display_alarm)
      assert contains_block?(lines, @override_alarm)
      assert Enum.count(lines, &(&1 == "BEGIN:VALARM")) == 2
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
