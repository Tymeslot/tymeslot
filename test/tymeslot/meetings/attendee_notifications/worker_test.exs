defmodule Tymeslot.Meetings.AttendeeNotifications.WorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
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
end
