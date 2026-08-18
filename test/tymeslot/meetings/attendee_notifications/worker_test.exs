defmodule Tymeslot.Meetings.AttendeeNotifications.WorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :meetings
  @moduletag :notifications

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  setup do
    starts_at = ~U[2026-01-01 10:00:00.000000Z]
    ends_at = ~U[2026-01-01 11:00:00.000000Z]

    baseline_state =
      LastNotifiedState.serialise(
        %{
          title: "original",
          starts_at: starts_at,
          ends_at: ends_at,
          location: "",
          description: "",
          video_link: nil
        },
        [%{email: "a@x.com"}]
      )

    event =
      insert(:provider_calendar_event,
        summary: "original",
        location: "",
        description: "",
        start_at: starts_at,
        end_at: ends_at,
        attendees: [%{"email" => "a@x.com"}],
        ical_sequence: 0,
        last_notified_state: baseline_state
      )

    {:ok, event: event, baseline_state: baseline_state}
  end

  describe "perform/1 for provider_calendar_event updates" do
    test "re-diffs at execution and persists new baseline when fields changed", %{event: event} do
      {:ok, event} =
        event
        |> Changeset.change(summary: "new title")
        |> Repo.update()

      args = %{
        "event_id" => event.id,
        "kind" => "provider_calendar_event",
        "action" => "update"
      }

      assert :ok = perform_job(Worker, args)

      reloaded = Repo.get!(ProviderCalendarEventSchema, event.id)
      assert reloaded.ical_sequence == 1
      assert reloaded.last_notified_state["title"] == "new title"
    end

    test "no-ops when diff is empty (user reverted edits)", %{event: event} do
      args = %{
        "event_id" => event.id,
        "kind" => "provider_calendar_event",
        "action" => "update"
      }

      assert :ok = perform_job(Worker, args)

      reloaded = Repo.get!(ProviderCalendarEventSchema, event.id)
      assert reloaded.ical_sequence == 0
      assert reloaded.last_notified_state == event.last_notified_state
    end
  end

  describe "perform/1 for provider_calendar_event deletes" do
    test "bumps sequence and persists new baseline", %{event: event} do
      {:ok, event} =
        event
        |> Changeset.change(summary: "about to delete")
        |> Repo.update()

      args = %{
        "event_id" => event.id,
        "kind" => "provider_calendar_event",
        "action" => "delete"
      }

      assert :ok = perform_job(Worker, args)

      reloaded = Repo.get!(ProviderCalendarEventSchema, event.id)
      assert reloaded.ical_sequence == 1
      assert reloaded.last_notified_state["title"] == "about to delete"
    end
  end

  describe "perform/1 for meeting updates" do
    test "re-diffs at execution and persists new baseline when title changed" do
      starts_at = ~U[2026-03-01 09:00:00Z]
      ends_at = ~U[2026-03-01 10:00:00Z]

      baseline_state =
        LastNotifiedState.serialise(
          %{
            title: "original title",
            starts_at: starts_at,
            ends_at: ends_at,
            location: "",
            description: "",
            video_link: nil
          },
          [%{email: "attendee@example.com"}]
        )

      # current_event_map prefers :summary over :title, so set both to the
      # updated value to ensure the diff sees a changed title.
      meeting =
        insert(:meeting,
          title: "updated title",
          summary: "updated title",
          start_time: starts_at,
          end_time: ends_at,
          location: nil,
          description: nil,
          attendee_email: "attendee@example.com",
          ical_sequence: 0,
          last_notified_state: baseline_state
        )

      args = %{
        "event_id" => meeting.id,
        "kind" => "meeting",
        "action" => "update"
      }

      assert :ok = perform_job(Worker, args)

      reloaded = Repo.get!(MeetingSchema, meeting.id)
      assert reloaded.ical_sequence == 1
      assert reloaded.last_notified_state["title"] == "updated title"
    end

    test "no-ops when diff is empty" do
      starts_at = ~U[2026-03-01 09:00:00Z]
      ends_at = ~U[2026-03-01 10:00:00Z]

      baseline_state =
        LastNotifiedState.serialise(
          %{
            title: "same title",
            starts_at: starts_at,
            ends_at: ends_at,
            location: "",
            description: "",
            video_link: nil
          },
          [%{email: "attendee@example.com"}]
        )

      meeting =
        insert(:meeting,
          title: "same title",
          summary: "same title",
          start_time: starts_at,
          end_time: ends_at,
          location: nil,
          description: nil,
          attendee_email: "attendee@example.com",
          ical_sequence: 0,
          last_notified_state: baseline_state
        )

      args = %{
        "event_id" => meeting.id,
        "kind" => "meeting",
        "action" => "update"
      }

      assert :ok = perform_job(Worker, args)

      reloaded = Repo.get!(MeetingSchema, meeting.id)
      assert reloaded.ical_sequence == 0
    end
  end

  describe "perform/1 with missing event" do
    test "returns :ok and does not crash" do
      args = %{
        "event_id" => 99_999_999,
        "kind" => "provider_calendar_event",
        "action" => "update"
      }

      assert :ok = perform_job(Worker, args)
    end
  end

  describe "perform/1 excludes attendees who have declined" do
    test "notifies the active attendees but skips the one who declined" do
      event =
        event_with_attendees([{"active@x.com", "needs_action"}, {"declined@x.com", "declined"}])

      assert :ok = perform_job(Worker, update_args(event))

      emails = notification_recipient_emails()
      assert "active@x.com" in emails
      refute "declined@x.com" in emails
    end

    test "enqueues no notification when every attendee has declined (but still re-bases)" do
      event = event_with_attendees([{"declined@x.com", "declined"}])

      assert :ok = perform_job(Worker, update_args(event))

      assert notification_recipient_emails() == []
      # The edit is real, so the sequence/baseline still advances — we simply
      # have no one to email.
      assert Repo.get!(ProviderCalendarEventSchema, event.id).ical_sequence == 1
    end
  end

  # Inserts a provider event whose title differs from its notified baseline (so
  # the diff is non-empty) and whose attendees carry the given response statuses.
  defp event_with_attendees(attendees) do
    starts_at = ~U[2026-02-01 10:00:00.000000Z]
    ends_at = ~U[2026-02-01 11:00:00.000000Z]

    baseline =
      LastNotifiedState.serialise(
        %{
          title: "before",
          starts_at: starts_at,
          ends_at: ends_at,
          location: "",
          description: "",
          video_link: nil
        },
        Enum.map(attendees, fn {email, _status} -> %{email: email} end)
      )

    insert(:provider_calendar_event,
      summary: "after",
      location: "",
      description: "",
      start_at: starts_at,
      end_at: ends_at,
      attendees:
        Enum.map(attendees, fn {email, status} ->
          %{"email" => email, "response_status" => status}
        end),
      ical_sequence: 0,
      last_notified_state: baseline
    )
  end

  defp update_args(event) do
    %{"event_id" => event.id, "kind" => "provider_calendar_event", "action" => "update"}
  end

  defp notification_recipient_emails do
    [worker: Tymeslot.Workers.EmailWorker]
    |> all_enqueued()
    |> Enum.filter(&(&1.args["action"] == "send_event_update_notification"))
    |> Enum.flat_map(&(&1.args["attendee_emails"] || []))
  end
end
