defmodule Tymeslot.CalendarGrid.EventDeletionNotifyTest do
  @moduledoc """
  `CalendarGrid.delete_event/4` with `notify_attendees: true` sends each
  attendee a cancellation, and only once the calendar has deleted the event:
  never for a delete that failed or was queued for the next sync, and never
  for a booking, whose cancelled meeting tells its attendee itself.

  The provider delete is stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`). What the cancellation email says is pinned in
  `AttendeeNotifications.ChangeEmailDeliveryTest`.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :notifications
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    caldav =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    %{user: user, caldav: caldav}
  end

  describe "delete_event/4 telling the attendees" do
    @attendees [%{"email" => "guest@example.com"}, %{"email" => "other@example.com"}]

    test "sends each attendee a cancellation once the calendar deleted the event", %{
      user: user,
      caldav: caldav
    } do
      event = insert_event(caldav, %{attendees: @attendees})
      expect_delete(:ok)

      assert {:ok, %{attendees_notified: :sent}} =
               CalendarGrid.delete_event(user.id, event, :occurrence, notify_attendees: true)

      assert Enum.sort(cancelled_to()) == ["guest@example.com", "other@example.com"]
      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
    end

    test "sends nothing unless asked", %{user: user, caldav: caldav} do
      event = insert_event(caldav, %{attendees: @attendees})
      expect_delete(:ok)

      assert {:ok, %{attendees_notified: :none}} = CalendarGrid.delete_event(user.id, event)
      assert cancelled_to() == []
    end

    test "sends nothing for a delete queued for the next sync", %{user: user, caldav: caldav} do
      event = insert_event(caldav, %{attendees: @attendees})
      expect_delete({:error, :network_error})

      assert {:error, %{retry: :queued}} =
               CalendarGrid.delete_event(user.id, event, :occurrence, notify_attendees: true)

      assert cancelled_to() == []
    end

    test "sends nothing for a delete the calendar refused", %{user: user, caldav: caldav} do
      event = insert_event(caldav, %{attendees: @attendees})
      expect_delete({:error, :unauthorized})

      assert {:error, %{retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, event, :occurrence, notify_attendees: true)

      assert cancelled_to() == []
    end

    # The cancelled meeting tells its attendee itself.
    test "leaves a booking's attendee to the meeting's own cancellation", %{
      user: user,
      caldav: caldav
    } do
      TestMocks.setup_email_mocks()
      event = insert_event(caldav, %{attendees: @attendees})

      insert(:meeting,
        calendar_integration_id: caldav.id,
        provider_event_id: event.provider_event_id,
        attendee_email: "guest@example.com"
      )

      expect_delete(:ok)

      assert {:ok, %{linked_meeting: :cancelled, attendees_notified: :none}} =
               CalendarGrid.delete_event(user.id, event, :occurrence, notify_attendees: true)

      assert cancelled_to() == []
    end

    test "says a whole-series delete cancels every occurrence", %{user: user} do
      google = insert(:calendar_integration, user: user, provider: "google")

      first =
        insert_event(
          google,
          Map.put(google_occurrence("series-1", "20260601T090000Z"), :attendees, @attendees)
        )

      second = insert_event(google, google_occurrence("series-1", "20260608T090000Z"))
      expect_delete(:ok)

      assert {:ok, %{attendees_notified: :sent}} =
               CalendarGrid.delete_event(user.id, first, :series, notify_attendees: true)

      jobs = cancellation_jobs()
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.args["event_series"] == true))

      for event <- [first, second] do
        assert ProviderCalendarEventQueries.get_by_uid(google.id, event.uid) ==
                 {:error, :not_found}
      end
    end

    test "an occurrence's cancellation is of that occurrence alone", %{user: user} do
      google = insert(:calendar_integration, user: user, provider: "google")

      first =
        insert_event(
          google,
          Map.put(google_occurrence("series-1", "20260601T090000Z"), :attendees, @attendees)
        )

      expect_delete(:ok)

      assert {:ok, %{attendees_notified: :sent}} =
               CalendarGrid.delete_event(user.id, first, :occurrence, notify_attendees: true)

      jobs = cancellation_jobs()
      assert length(jobs) == 2

      assert Enum.all?(jobs, fn job ->
               job.args["event_series"] == false and job.args["event_uid"] == first.uid and
                 job.args["event_start_at"] == "2026-06-01T09:00:00.000000Z"
             end)
    end
  end

  describe "delete_event/4 when the cancellation cannot be sent" do
    # An all-day row without its end date makes building the cancellation
    # raise, as any unexpected row shape could. The delete has happened, so
    # the failure is logged, rendered through `LogFormat`: a stacktrace
    # formatted with its arguments can carry the event and its attendees.
    test "logs the failure without the arguments of the call that raised", %{
      user: user,
      caldav: caldav
    } do
      event =
        insert_event(caldav, %{
          attendees: @attendees,
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-06-01],
          end_date: nil
        })

      expect_delete(:ok)

      log_event =
        LogCapture.with_capture(fn ->
          assert {:ok, %{attendees_notified: :failed}} =
                   CalendarGrid.delete_event(user.id, event, :occurrence, notify_attendees: true)

          LogCapture.await_log("could not enqueue the attendees' cancellation")
        end)

      meta = LogCapture.user_metadata(log_event)
      assert meta.error =~ "FunctionClauseError"
      refute meta.error =~ "to_iso8601(nil"
      assert meta.stacktrace =~ "Date.to_iso8601/2"
    end
  end

  defp cancellation_jobs do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.filter(
      &(&1.args["action"] == "send_calendar_invitation" and &1.args["method"] == "cancel")
    )
  end

  defp cancelled_to, do: Enum.map(cancellation_jobs(), & &1.args["attendee_email"])

  defp insert_event(integration, attrs) do
    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Design review",
      provider: integration.provider,
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/design-review.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp expect_delete(result) do
    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> result end)
  end

  # An expanded Google occurrence: an id of its own, naming its master's.
  defp google_occurrence(series_id, stamp) do
    %{
      uid: "#{series_id}@google.com_#{stamp}",
      provider_calendar_id: "primary",
      provider_event_id: "#{series_id}_#{stamp}",
      recurring_event_id: series_id
    }
  end
end
