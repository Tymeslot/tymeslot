defmodule Tymeslot.Meetings.AttendeeNotificationsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :meetings
  @moduletag :notifications

  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias Tymeslot.Meetings.AttendeeNotifications.Dispatcher
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Workers.EmailWorker

  describe "event_created/2" do
    test "returns {:ok, :noop} when there are no attendees" do
      event = insert(:provider_calendar_event, attendees: [])
      assert {:ok, :noop} = AttendeeNotifications.event_created(event, [])
    end

    test "enqueues a calendar invitation email per attendee" do
      event =
        insert(:provider_calendar_event,
          summary: "Kickoff",
          attendees: [%{"email" => "a@x.com"}, %{"email" => "b@x.com"}]
        )

      attendees = [%{email: "a@x.com"}, %{email: "b@x.com"}]

      assert {:ok, :sent} = AttendeeNotifications.event_created(event, attendees)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "attendee_email" => "a@x.com"}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "attendee_email" => "b@x.com"}
      )
    end

    test "an all-day event's invitation carries its dates instead of instants" do
      event =
        insert(:provider_calendar_event,
          all_day: true,
          start_date: ~D[2026-10-12],
          end_date: ~D[2026-10-15],
          start_at: nil,
          end_at: nil
        )

      assert {:ok, :sent} = AttendeeNotifications.event_created(event, [%{email: "a@x.com"}])

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "a@x.com",
          "event_all_day" => true,
          "event_start_date" => "2026-10-12",
          "event_end_date" => "2026-10-15",
          "event_start_at" => nil
        }
      )
    end

    test "enqueues a :request invitation for a MeetingSchema attendee" do
      meeting = insert(:meeting, attendee_email: "guest@example.com")
      attendees = [%{email: "guest@example.com"}]

      assert {:ok, :sent} = AttendeeNotifications.event_created(meeting, attendees)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "guest@example.com",
          "method" => "request"
        }
      )
    end
  end

  describe "event_updated/3" do
    test "returns {:ok, :no_changes} when nothing notifiable changed" do
      starts_at = ~U[2026-02-01 10:00:00.000000Z]
      ends_at = ~U[2026-02-01 11:00:00.000000Z]

      event =
        insert(:provider_calendar_event,
          summary: "same",
          start_at: starts_at,
          end_at: ends_at,
          location: "HQ",
          description: "",
          attendees: [%{"email" => "a@x.com"}]
        )

      assert {:ok, :no_changes} =
               AttendeeNotifications.event_updated(event, event, [%{email: "a@x.com"}])
    end

    test "asks to notify when an all-day event moves to other days" do
      event =
        insert(:provider_calendar_event,
          all_day: true,
          start_date: ~D[2026-10-12],
          end_date: ~D[2026-10-13],
          start_at: nil,
          end_at: nil,
          attendees: [%{"email" => "a@x.com"}]
        )

      moved = %{event | start_date: ~D[2026-10-19], end_date: ~D[2026-10-20]}

      assert {:needs_confirmation, %ChangeSummary{changed_fields: [:start_date, :end_date]}} =
               AttendeeNotifications.event_updated(event, moved, [%{email: "a@x.com"}])
    end

    test "returns {:ok, :no_changes} when there are no attendees regardless of diff" do
      event = insert(:provider_calendar_event, summary: "old")
      changed = %{event | summary: "new"}

      assert {:ok, :no_changes} = AttendeeNotifications.event_updated(event, changed, [])
    end

    test "returns {:needs_confirmation, summary} when a notifiable field changed" do
      starts_at = ~U[2026-02-01 10:00:00.000000Z]
      ends_at = ~U[2026-02-01 11:00:00.000000Z]

      event =
        insert(:provider_calendar_event,
          summary: "original",
          start_at: starts_at,
          end_at: ends_at,
          attendees: [%{"email" => "a@x.com"}]
        )

      new_event = %{
        id: event.id,
        uid: event.uid,
        summary: "renamed",
        start_at: starts_at,
        end_at: ends_at,
        location: nil,
        description: nil,
        ical_sequence: event.ical_sequence
      }

      assert {:needs_confirmation, %ChangeSummary{changed_fields: [:title]}} =
               AttendeeNotifications.event_updated(event, new_event, [%{email: "a@x.com"}])
    end
  end

  describe "event_updated_confirm/3" do
    test "delegates to Dispatcher.schedule_update/2" do
      event = insert(:provider_calendar_event)
      summary = %ChangeSummary{changed_fields: [:title], next_sequence: 1}

      assert {:ok, :sent} =
               AttendeeNotifications.event_updated_confirm(event, summary, [
                 %{email: "a@x.com"}
               ])

      assert_enqueued(
        worker: Worker,
        args: %{"event_id" => event.id, "kind" => "provider_calendar_event", "action" => "update"}
      )
    end
  end

  describe "attendees_added/2" do
    test "returns {:ok, :noop} for an empty list" do
      event = insert(:provider_calendar_event)
      assert {:ok, :noop} = AttendeeNotifications.attendees_added(event, [])
    end

    test "sends one invitation per newly-added attendee" do
      event = insert(:provider_calendar_event)

      assert {:ok, :sent} =
               AttendeeNotifications.attendees_added(event, [%{email: "new@x.com"}])

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "attendee_email" => "new@x.com"}
      )
    end
  end

  describe "attendees_removed/2" do
    test "returns {:ok, :noop} for an empty list" do
      event = insert(:provider_calendar_event)
      assert {:ok, :noop} = AttendeeNotifications.attendees_removed(event, [])
    end

    test "sends a cancel message per removed attendee" do
      event = insert(:provider_calendar_event, ical_sequence: 2)

      assert {:ok, :sent} =
               AttendeeNotifications.attendees_removed(event, [%{email: "gone@x.com"}])

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "gone@x.com",
          "method" => "cancel"
        }
      )
    end
  end

  describe "event_deleted/3" do
    test "returns {:ok, :no_attendees} when there is nobody to notify" do
      event = insert(:provider_calendar_event)
      user = event.calendar_integration.user
      assert {:ok, :no_attendees} = AttendeeNotifications.event_deleted(event, [], user.id)
    end

    test "returns {:needs_confirmation, N} with the attendee count" do
      event = insert(:provider_calendar_event)
      user = event.calendar_integration.user
      attendees = [%{email: "a@x.com"}, %{email: "b@x.com"}, %{email: "c@x.com"}]

      assert {:needs_confirmation, 3} =
               AttendeeNotifications.event_deleted(event, attendees, user.id)
    end

    test "asks the organiser, known by their own address, the integration's or the calendar's" do
      user = insert(:user, email: "Me@Example.com")

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_email: "me@work.example"
        )

      attendees = [%{email: "a@x.com"}]

      for {organiser, calendar_id} <- [
            {" me@example.com ", "primary"},
            {"ME@WORK.EXAMPLE", "primary"},
            {"team123@group.calendar.google.com", "team123@group.calendar.google.com"},
            {nil, "primary"}
          ] do
        event =
          insert(:provider_calendar_event,
            calendar_integration: integration,
            provider_calendar_id: calendar_id,
            organiser: organiser && %{"email" => organiser}
          )

        assert {:needs_confirmation, 1} =
                 AttendeeNotifications.event_deleted(event, attendees, user.id),
               "expected #{inspect(organiser)} to count as the user's own address"
      end
    end

    test "returns {:ok, :not_organiser} for an event someone else organises" do
      event = insert(:provider_calendar_event, organiser: %{"email" => "boss@elsewhere.example"})
      user = event.calendar_integration.user

      assert {:ok, :not_organiser} =
               AttendeeNotifications.event_deleted(event, [%{email: "a@x.com"}], user.id)
    end
  end

  describe "event_deleted_confirm/3" do
    test "enqueues one cancellation per attendee at once, carrying the event" do
      user = insert(:user)

      event =
        insert(:provider_calendar_event,
          summary: "Standup",
          ical_sequence: 4,
          attendees: [%{"email" => "a@x.com"}, %{"email" => "b@x.com"}]
        )

      assert {:ok, :sent} = AttendeeNotifications.event_deleted_confirm(event, user.id, :series)

      jobs = all_enqueued(worker: EmailWorker)

      assert jobs |> Enum.map(& &1.args["attendee_email"]) |> Enum.sort() == [
               "a@x.com",
               "b@x.com"
             ]

      for job <- jobs do
        assert %{
                 "action" => "send_calendar_invitation",
                 "user_id" => user_id,
                 "event_title" => "Standup",
                 "event_uid" => uid,
                 "method" => "cancel",
                 "sequence" => 5,
                 "event_series" => true
               } = job.args

        assert user_id == user.id
        assert uid == event.uid
        refute job.scheduled_at > DateTime.utc_now()
      end

      assert all_enqueued(worker: Worker) == []
    end

    test "sends nothing for an event someone else organises" do
      event =
        insert(:provider_calendar_event,
          organiser: %{"email" => "boss@elsewhere.example"},
          attendees: [%{"email" => "boss@elsewhere.example"}, %{"email" => "b@x.com"}]
        )

      user = event.calendar_integration.user

      assert {:ok, :noop} = AttendeeNotifications.event_deleted_confirm(event, user.id, :series)
      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "series_updated_confirm/4" do
    test "enqueues one update at once, carrying the event before and after the edit" do
      user = insert(:user, email: "owner@x.com")
      integration = insert(:calendar_integration, user: user)

      original =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "Weekly sync",
          ical_sequence: 2,
          all_day: false,
          start_at: ~U[2026-06-01 09:00:00.000000Z],
          end_at: ~U[2026-06-01 10:00:00.000000Z],
          attendees: [
            %{"email" => "a@x.com"},
            %{"email" => "owner@x.com"},
            %{"email" => "no@x.com", "response_status" => "declined"}
          ]
        )

      updated = %{
        original
        | start_at: ~U[2026-06-01 14:00:00.000000Z],
          end_at: ~U[2026-06-01 15:00:00.000000Z]
      }

      assert {:ok, :sent} =
               AttendeeNotifications.series_updated_confirm(original, updated, user.id, :all)

      assert [job] = all_enqueued(worker: EmailWorker)

      assert %{
               "action" => "send_event_update_notification",
               "attendee_emails" => ["a@x.com"],
               "before_start_at" => "2026-06-01T09:00:00.000000Z",
               "method" => "request",
               "sequence" => 3,
               "series" => "all",
               "event" => %{"start_at" => "2026-06-01T14:00:00.000000Z", "uid" => uid}
             } = job.args

      assert uid == original.uid
      refute job.scheduled_at > DateTime.utc_now()
      assert all_enqueued(worker: Worker) == []
    end

    test "returns {:ok, :noop} when nobody is left to tell" do
      event = insert(:provider_calendar_event, attendees: [])
      user = event.calendar_integration.user

      assert {:ok, :noop} =
               AttendeeNotifications.series_updated_confirm(event, event, user.id, :following)

      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "pending?/1 and cancel_pending/1" do
    test "pending?/1 is false before scheduling, true after" do
      event = insert(:provider_calendar_event)
      refute AttendeeNotifications.pending?(event)

      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      assert AttendeeNotifications.pending?(event)
    end

    test "cancel_pending/1 removes scheduled jobs for the event" do
      event = insert(:provider_calendar_event)
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)

      :ok = AttendeeNotifications.cancel_pending(event)

      refute AttendeeNotifications.pending?(event)
    end

    test "pending?/1 ignores a job of the other kind that happens to share the id" do
      event = insert(:provider_calendar_event)

      # `meetings` and `provider_calendar_events` number their rows
      # independently, so the same integer names a different event in each.
      # A meeting job must not make this provider event look pending.
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :meeting)

      refute AttendeeNotifications.pending?(event)
      assert Dispatcher.pending?(event.id, :meeting)
    end
  end
end
