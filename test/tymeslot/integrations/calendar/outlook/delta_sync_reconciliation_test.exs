defmodule Tymeslot.Integrations.Calendar.Outlook.DeltaSyncReconciliationTest do
  @moduledoc """
  The Outlook delta sweep reconciling the bookings its changes link to: moves
  flagged once, and never on the strength of an event read before Tymeslot's
  own write to it landed.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.DeltaSync
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  # The circuit breaker runs in a GenServer process that is separate from the
  # test process. Use global mode so mocks are visible from that process.
  setup :set_mox_global
  setup :verify_on_exit!

  defp outlook_integration(attrs) do
    defaults = [
      provider: "outlook",
      access_token_encrypted: Encryption.encrypt("test-access-token"),
      refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    ]

    insert(:calendar_integration, Keyword.merge(defaults, attrs))
  end

  defp graph_event(overrides) do
    Map.merge(
      %{
        "id" => "graph-id-#{System.unique_integer([:positive])}",
        "iCalUId" => "ical-uid-#{System.unique_integer([:positive])}",
        "subject" => "Test Event",
        "body" => %{"content" => ""},
        "location" => %{"displayName" => ""},
        "showAs" => "busy",
        "sensitivity" => "normal",
        "isAllDay" => false,
        "isCancelled" => false,
        "responseStatus" => %{"response" => "accepted"},
        "start" => %{"dateTime" => "2024-03-15T14:00:00Z", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00Z", "timeZone" => "UTC"},
        "organizer" => %{
          "emailAddress" => %{"address" => "org@example.com", "name" => "Organiser"}
        },
        "attendees" => [],
        "reminderMinutesBeforeStart" => 15,
        "recurrence" => nil,
        "seriesMasterId" => nil
      },
      overrides
    )
  end

  describe "fetch_and_apply/1 - linked meetings" do
    setup do
      TestMocks.setup_email_mocks()
      Application.put_env(:swoosh, :shared_test_process, self())
      on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
      :ok
    end

    defp booking_moved_in_outlook do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old-token"
        )

      start_time = DateTime.add(DateTime.utc_now(:second), 86_400, :second)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "graph-id-moved",
          start_time: start_time,
          end_time: DateTime.add(start_time, 1800, :second)
        )

      moved_start = DateTime.add(start_time, 7200, :second)

      moved =
        graph_event(%{
          "id" => "graph-id-moved",
          "start" => %{"dateTime" => DateTime.to_iso8601(moved_start), "timeZone" => "UTC"},
          "end" => %{
            "dateTime" => moved_start |> DateTime.add(1800, :second) |> DateTime.to_iso8601(),
            "timeZone" => "UTC"
          }
        })

      {integration, meeting, moved}
    end

    defp expect_delta(events, on_read \\ fn -> :ok end) do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        on_read.()

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => events,
               "@odata.deltaLink" => "https://graph.microsoft.com/v1.0/me/calendarView/delta"
             })
         }}
      end)
    end

    defp complete_calendar_jobs(fields) do
      Repo.update_all(Oban.Job, set: Keyword.put(fields, :state, "completed"))
    end

    test "a second sweep over the same changes does not tell the host again" do
      {integration, meeting, moved} = booking_moved_in_outlook()
      organizer_email = meeting.organizer_email

      expect_delta([moved])
      assert :ok = DeltaSync.fetch_and_apply(integration)
      assert_received {:email, %{to: [{_name, ^organizer_email}]}}

      # A crash before the delta link was stored hands the next sweep the
      # same changes again.
      expect_delta([moved])
      {:ok, integration} = CalendarIntegrationQueries.get(integration.id)
      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert {:ok, %{calendar_sync_status: "externally_modified"}} =
               MeetingQueries.get_meeting(meeting.id)

      refute_received {:email, _email}
    end

    test "does not flag a booking while Tymeslot's own write to it is pending" do
      {integration, meeting, moved} = booking_moved_in_outlook()
      {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")

      expect_delta([moved])
      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert {:ok, %{calendar_sync_status: nil}} = MeetingQueries.get_meeting(meeting.id)
      refute_received {:email, _email}
    end

    # The write finishes while the sweep is still reading and processing, so
    # by the time the booking is reconciled nothing is pending any more; the
    # event read may still predate it.
    test "does not flag a booking whose Tymeslot write completed while the sweep read it" do
      {integration, meeting, moved} = booking_moved_in_outlook()
      {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")

      expect_delta([moved], fn ->
        complete_calendar_jobs(completed_at: DateTime.utc_now())
      end)

      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert {:ok, %{calendar_sync_status: nil}} = MeetingQueries.get_meeting(meeting.id)
      refute_received {:email, _email}
    end

    # The webhook path reads one event rather than a delta, under the same rule.
    test "a webhook fetch does not flag a booking whose Tymeslot write completed during the read" do
      {integration, meeting, moved} = booking_moved_in_outlook()
      {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        complete_calendar_jobs(completed_at: DateTime.utc_now())
        {:ok, %Req.Response{status: 200, body: Jason.encode!(moved)}}
      end)

      assert :ok =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "graph_resource_id" => moved["id"]
               })

      assert {:ok, %{calendar_sync_status: nil}} = MeetingQueries.get_meeting(meeting.id)
      refute_received {:email, _email}
    end

    test "flags a booking whose Tymeslot write completed before the sweep began" do
      {integration, meeting, moved} = booking_moved_in_outlook()
      {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")
      complete_calendar_jobs(completed_at: DateTime.add(DateTime.utc_now(), -60, :second))

      expect_delta([moved])
      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert {:ok, %{calendar_sync_status: "externally_modified"}} =
               MeetingQueries.get_meeting(meeting.id)

      organizer_email = meeting.organizer_email
      assert_received {:email, %{to: [{_name, ^organizer_email}]}}
    end

    # The sweep is the only way an integration without a Graph subscription
    # (no WEBHOOK_BASE_URL, or one Microsoft cannot reach) hears of a change,
    # so a booking moved in Outlook has to be reconciled here exactly as the
    # webhook path (`SyncOutlookCalendarWorker`) reconciles it.
    test "reconciles a meeting whose event was moved in Outlook" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old-token"
        )

      start_time = DateTime.add(DateTime.utc_now(:second), 86_400, :second)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "graph-id-moved",
          start_time: start_time,
          end_time: DateTime.add(start_time, 1800, :second)
        )

      moved_start = DateTime.add(start_time, 7200, :second)

      moved =
        graph_event(%{
          "id" => "graph-id-moved",
          "start" => %{"dateTime" => DateTime.to_iso8601(moved_start), "timeZone" => "UTC"},
          "end" => %{
            "dateTime" => moved_start |> DateTime.add(1800, :second) |> DateTime.to_iso8601(),
            "timeZone" => "UTC"
          }
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [moved],
               "@odata.deltaLink" => "https://graph.microsoft.com/v1.0/me/calendarView/delta"
             })
         }}
      end)

      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert {:ok, %{calendar_sync_status: "externally_modified"}} =
               MeetingQueries.get_meeting(meeting.id)
    end
  end
end
