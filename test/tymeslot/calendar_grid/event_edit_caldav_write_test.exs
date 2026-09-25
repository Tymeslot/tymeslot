defmodule Tymeslot.CalendarGrid.EventEditCalDAVWriteTest do
  @moduledoc """
  What a grid edit of a synced CalDAV event actually puts on the wire.

  `EventEditTest` stops at the `:calendar_module` seam and pins the payload;
  this module points that seam back at the runtime module so the edit travels
  the whole way down — grid domain, provider adapter, CalDAV writer — and the
  iCalendar document the server receives can be read.

  The journey is worth its cost because the loss it guards against is
  invisible from either end. The payload is complete, the write succeeds, and
  the organiser's rename lands; it is only in the document that an event
  created in another client comes back with its participants replaced by
  `CONTACT` lines and their invitations dropped.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  @attendee_ada "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada:mailto:ada@example.com"
  @attendee_bob "ATTENDEE;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:bob@example.com"

  # The event as it arrived from the server: written in another client, with
  # two attendees who have already answered.
  @synced_ical """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  PRODID:-//Mozilla.org/NONSGML Mozilla Calendar V1.1//EN\r
  BEGIN:VEVENT\r
  UID:sprint-review\r
  DTSTAMP:20260901T090000Z\r
  DTSTART:20260910T090000Z\r
  DTEND:20260910T100000Z\r
  SUMMARY:Sprint review\r
  CATEGORIES:WORK\r
  #{@attendee_ada}\r
  #{@attendee_bob}\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  setup do
    previous_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous_module do
        Application.put_env(:tymeslot, :calendar_module, previous_module)
      else
        Application.delete_env(:tymeslot, :calendar_module)
      end
    end)

    user = insert(:user)

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
        uid: "sprint-review",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/sprint-review.ics",
        summary: "Sprint review",
        start_at: ~U[2026-09-10 09:00:00.000000Z],
        end_at: ~U[2026-09-10 10:00:00.000000Z],
        all_day: false,
        attendees: [%{"email" => "ada@example.com", "name" => "Ada", "status" => "accepted"}],
        etag: "\"etag-1\"",
        raw_ical: @synced_ical,
        sync_state: "synced"
      )

    %{user: user, integration: integration, event: event}
  end

  describe "renaming a synced CalDAV event from the grid" do
    test "sends the stored document with only the title rewritten", %{
      user: user,
      event: event
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
        send(test_pid, {:put, url, body, headers})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert updated.summary == "Renamed"

      assert_received {:put, url, body, headers}
      lines = LineFolder.unfold_lines(body)

      # The attendees the organiser never touched, with the responses they
      # gave, exactly as the server had them.
      assert @attendee_ada in lines
      assert @attendee_bob in lines
      refute body =~ "CONTACT:"

      assert "SUMMARY:Renamed" in lines
      assert "CATEGORIES:WORK" in lines
      assert url == "https://caldav.example.com/cal/sprint-review.ics"
      assert {"If-Match", "\"etag-1\""} in headers
    end

    test "leaves the cached document and ETag for the next write to use", %{
      user: user,
      integration: integration,
      event: event
    } do
      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.raw_ical == @synced_ical
      assert row.etag == "\"etag-1\""
      assert row.summary == "Renamed"
    end
  end

  # The grid removes a guest by writing the shortened list
  # (`AttendeeManagement.apply_remove_attendee/3`). The guest has already been
  # emailed a cancellation by then, so a document that kept her line would put
  # her back in the grid on the next sync.
  describe "changing the guests of a synced CalDAV event from the grid" do
    defp expect_put do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn _url, body, _headers, _opts ->
        send(test_pid, {:put, body})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)
    end

    defp sent_attendee_lines do
      assert_received {:put, body}
      body |> LineFolder.unfold_lines() |> Enum.filter(&String.starts_with?(&1, "ATTENDEE"))
    end

    test "removing a guest takes her ATTENDEE line off the server's document", %{
      user: user,
      event: event
    } do
      expect_put()

      # The list the grid sends once Bob is removed from a cache that held both.
      remaining = [%{"email" => "ada@example.com", "name" => "Ada", "status" => "accepted"}]
      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, %{attendees: remaining})
      assert updated.attendees == remaining

      # Ada's reply travels with her, verbatim, rather than being rebuilt from
      # the cache, which holds no ROLE for her.
      assert sent_attendee_lines() == [@attendee_ada]
    end

    test "adding a guest writes a client-scheduled ATTENDEE and keeps the others' replies", %{
      user: user,
      event: event
    } do
      expect_put()

      attendees = [
        %{"email" => "ada@example.com", "name" => "Ada", "status" => "accepted"},
        %{"email" => "bob@example.com", "name" => nil, "status" => "accepted"},
        %{"email" => "cleo@example.com", "name" => nil, "status" => "needs_action"}
      ]

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{attendees: attendees})

      # SCHEDULE-AGENT=CLIENT: stored, but not mailed by the server, because
      # Tymeslot has already sent the invitation itself.
      assert sent_attendee_lines() == [
               @attendee_ada,
               @attendee_bob,
               "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE:mailto:cleo@example.com"
             ]
    end
  end

  describe "editing one occurrence of a synced CalDAV series" do
    # The series as the server holds it: a Berlin master whose 29 September
    # occurrence was deleted earlier, which is the EXDATE a write of the
    # master's properties would rewrite in UTC.
    @series_href "/cal/weekly-standup.ics"
    @series_url "https://caldav.example.com/cal/weekly-standup.ics"
    @series_master [
      "BEGIN:VEVENT",
      "UID:weekly-standup",
      "DTSTAMP:20260901T090000Z",
      "DTSTART;TZID=Europe/Berlin:20260908T090000",
      "DTEND;TZID=Europe/Berlin:20260908T091500",
      "RRULE:FREQ=WEEKLY;BYDAY=TU",
      "EXDATE;TZID=Europe/Berlin:20260929T090000",
      "SUMMARY:Weekly standup",
      "END:VEVENT"
    ]
    @series_ical Enum.join(
                   ["BEGIN:VCALENDAR", "VERSION:2.0"] ++ @series_master ++ ["END:VCALENDAR"],
                   "\r\n"
                 ) <> "\r\n"

    setup %{integration: integration} do
      row = fn key, start_at ->
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "weekly-standup_#{key}",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: @series_href,
          summary: "Weekly standup",
          start_at: start_at,
          end_at: DateTime.add(start_at, 15, :minute),
          all_day: false,
          timezone: "Europe/Berlin",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
          provider_metadata: %{"uid" => "weekly-standup"},
          etag: "\"etag-1\"",
          raw_ical: @series_ical,
          sync_state: "synced"
        )
      end

      %{
        occurrence: row.("20260915T090000", ~U[2026-09-15 07:00:00.000000Z]),
        sibling: row.("20260922T090000", ~U[2026-09-22 07:00:00.000000Z])
      }
    end

    defp expect_series_put do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
        send(test_pid, {:put, url, body, headers})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)
    end

    defp vevent_blocks(body) do
      body
      |> LineFolder.unfold_lines()
      |> Enum.chunk_while(
        nil,
        fn
          "BEGIN:VEVENT", nil -> {:cont, ["BEGIN:VEVENT"]}
          "END:VEVENT", acc when is_list(acc) -> {:cont, Enum.reverse(["END:VEVENT" | acc]), nil}
          line, acc when is_list(acc) -> {:cont, [line | acc]}
          _line, nil -> {:cont, nil}
        end,
        fn _unterminated -> {:cont, nil} end
      )
    end

    test "a reschedule PUTs the series with an override in the series' zone", %{
      user: user,
      occurrence: occurrence
    } do
      expect_series_put()

      # 11:00 in Berlin (UTC+2) on 15 September.
      assert {:ok, updated} =
               CalendarGrid.update_event(user.id, occurrence, %{
                 start_at: ~U[2026-09-15 09:00:00.000000Z],
                 end_at: ~U[2026-09-15 09:15:00.000000Z]
               })

      assert updated.start_at == ~U[2026-09-15 09:00:00.000000Z]
      assert_received {:put, @series_url, body, headers}
      assert {"If-Match", "\"etag-1\""} in headers

      [master, override] = vevent_blocks(body)
      # The master goes back as the server wrote it, its EXDATE included.
      assert master == @series_master

      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260915T090000" in override
      assert "DTSTART;TZID=Europe/Berlin:20260915T110000" in override
      assert "DTEND;TZID=Europe/Berlin:20260915T111500" in override
      refute Enum.any?(override, &String.starts_with?(&1, ["RRULE", "EXDATE"]))
    end

    test "the occurrence keeps its edit and the series' rows share the new document", %{
      user: user,
      integration: integration,
      occurrence: occurrence,
      sibling: sibling,
      event: unrelated
    } do
      expect_series_put()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup, moved"})

      assert_received {:put, _url, body, _headers}
      [_master, override] = vevent_blocks(body)
      assert "SUMMARY:Standup\\, moved" in override
      # A rename leaves the occurrence where it was.
      assert "DTSTART;TZID=Europe/Berlin:20260915T090000" in override

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)
      assert row.summary == "Standup, moved"

      for uid <- [occurrence.uid, sibling.uid] do
        {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
        # The PUT came back without an ETag, so the next write re-reads first.
        assert {cached.raw_ical, cached.etag} == {body, nil}
      end

      {:ok, sibling_row} = ProviderCalendarEventQueries.get_by_uid(integration.id, sibling.uid)
      assert sibling_row.summary == "Weekly standup"

      {:ok, other} = ProviderCalendarEventQueries.get_by_uid(integration.id, unrelated.uid)
      assert {other.raw_ical, other.etag} == {@synced_ical, "\"etag-1\""}
    end

    # The series as the grid's first edit of 15 September left it, read back
    # by the sync: the override's cached row is whatever the normaliser makes
    # of it, not a hand-built one.
    defp synced_override_row(integration, recurrence_id) do
      document =
        Enum.join(
          ["BEGIN:VCALENDAR", "VERSION:2.0"] ++
            @series_master ++
            [
              "BEGIN:VEVENT",
              "UID:weekly-standup",
              "DTSTAMP:20260902T090000Z",
              recurrence_id,
              "DTSTART;TZID=Europe/Berlin:20260915T110000",
              "DTEND;TZID=Europe/Berlin:20260915T111500",
              "SUMMARY:Weekly standup, moved",
              "END:VEVENT",
              "END:VCALENDAR"
            ],
          "\r\n"
        ) <> "\r\n"

      {:ok, raws} = EventProcessor.parse_ical_events(document)

      {:ok, events} =
        ICalNormaliser.normalise_events(
          Enum.map(raws, &Map.put(&1, :href, @series_href)),
          %{
            calendar_integration_id: integration.id,
            provider_calendar_id: "/cal/",
            synced_at: DateTime.utc_now()
          },
          :caldav
        )

      synced = Enum.find(events, &(&1.uid == "weekly-standup_20260915T090000"))

      row =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: synced.uid,
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: @series_href,
          summary: synced.summary,
          start_at: synced.start_at,
          end_at: synced.end_at,
          all_day: false,
          timezone: synced.timezone,
          recurrence_rule: synced.recurrence_rule,
          provider_metadata: synced.provider_metadata,
          etag: "\"etag-2\"",
          raw_ical: document,
          sync_state: "synced"
        )

      {row, document}
    end

    for recurrence_id <- [
          "RECURRENCE-ID;TZID=Europe/Berlin:20260915T090000",
          "RECURRENCE-ID:20260915T070000Z"
        ] do
      test "a second edit keeps the occurrence in the series' zone (#{recurrence_id})", %{
        user: user,
        integration: integration,
        occurrence: first_edit
      } do
        # The row the first edit left is gone once the sync has read the
        # override back: it is replaced by the one the normaliser makes.
        ProviderCalendarEventQueries.delete_by_uid(integration.id, first_edit.uid)
        {occurrence, _document} = synced_override_row(integration, unquote(recurrence_id))
        expect_series_put()

        # 12:00 in Berlin (UTC+2) on 15 September.
        assert {:ok, _updated} =
                 CalendarGrid.update_event(user.id, occurrence, %{
                   start_at: ~U[2026-09-15 10:00:00.000000Z],
                   end_at: ~U[2026-09-15 10:15:00.000000Z]
                 })

        assert_received {:put, @series_url, body, _headers}
        assert [master, override] = vevent_blocks(body)
        assert master == @series_master
        assert unquote(recurrence_id) in override
        assert "DTSTART;TZID=Europe/Berlin:20260915T120000" in override
        assert "DTEND;TZID=Europe/Berlin:20260915T121500" in override
        assert "SUMMARY:Weekly standup, moved" in override
      end
    end

    test "a failed write is not queued and leaves the cache as it was", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, %{retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup, moved"})

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)

      assert {row.summary, row.sync_state, row.etag, row.raw_ical} ==
               {"Weekly standup", "synced", "\"etag-1\"", @series_ical}
    end

    # No `expect`: under `verify_on_exit!` a PUT that reached the server would
    # fail the test as an unexpected call.
    test "every following occurrence cannot be written yet", %{
      user: user,
      occurrence: occurrence
    } do
      assert {:error, %{reason: :unsupported_scope, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Daily standup"},
                 recurrence_scope: :following
               )
    end

    test "the one-off event on the same calendar is still editable", %{
      user: user,
      event: event
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn _url, body, _headers, _opts ->
        send(test_pid, {:put, body})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{
                 start_at: ~U[2026-09-10 11:00:00.000000Z],
                 end_at: ~U[2026-09-10 12:00:00.000000Z]
               })

      assert_received {:put, body}
      assert "DTSTART:20260910T110000Z" in LineFolder.unfold_lines(body)
    end
  end
end
