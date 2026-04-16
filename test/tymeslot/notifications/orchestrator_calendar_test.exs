defmodule Tymeslot.Notifications.OrchestratorCalendarTest do
  use Tymeslot.DataCase, async: false

  @moduletag :notifications

  alias Tymeslot.Notifications.Orchestrator

  defmodule MockWorker do
    @spec schedule_calendar_invitation(map()) :: :ok
    def schedule_calendar_invitation(params) do
      send(self(), {:scheduled_invitation, params})
      :ok
    end

    @spec schedule_event_update_notification(map()) :: :ok
    def schedule_event_update_notification(params) do
      send(self(), {:scheduled_event_update, params})
      :ok
    end
  end

  defmodule FailingWorker do
    @spec schedule_calendar_invitation(map()) :: :ok | {:error, String.t()}
    def schedule_calendar_invitation(%{attendee_email: "fail@example.com"}) do
      {:error, "Failed to schedule job"}
    end

    def schedule_calendar_invitation(params) do
      send(self(), {:scheduled_invitation, params})
      :ok
    end
  end

  defmodule FailingUpdateWorker do
    @spec schedule_event_update_notification(map()) :: {:error, String.t()}
    def schedule_event_update_notification(_params) do
      {:error, "Failed to schedule update job"}
    end
  end

  setup do
    original = Application.get_env(:tymeslot, :email_worker_module)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, :email_worker_module)
      else
        Application.put_env(:tymeslot, :email_worker_module, original)
      end
    end)

    :ok
  end

  defp event_details(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Team Sync",
        uid: "event-123",
        start_at: ~U[2026-04-10 10:00:00Z],
        end_at: ~U[2026-04-10 11:00:00Z]
      },
      overrides
    )
  end

  defp original_event(overrides) do
    Map.merge(
      %{
        uid: "event-uid-123",
        calendar_integration_id: 42,
        summary: "Team Sync",
        location: "Room 1",
        description: "Agenda TBD",
        start_at: ~U[2026-04-10 10:00:00Z],
        end_at: ~U[2026-04-10 11:00:00Z],
        attendees: nil
      },
      overrides
    )
  end

  describe "schedule_event_update_notification/2" do
    test "returns :ok immediately when attendees is nil" do
      Application.put_env(:tymeslot, :email_worker_module, MockWorker)
      event = original_event(%{attendees: nil})

      assert :ok = Orchestrator.schedule_event_update_notification(1, event)
      refute_received {:scheduled_event_update, _}
    end

    test "returns :ok immediately when attendees is empty list" do
      Application.put_env(:tymeslot, :email_worker_module, MockWorker)
      event = original_event(%{attendees: []})

      assert :ok = Orchestrator.schedule_event_update_notification(1, event)
      refute_received {:scheduled_event_update, _}
    end

    test "delegates to worker with correct params when attendees are present" do
      Application.put_env(:tymeslot, :email_worker_module, MockWorker)

      event =
        original_event(%{
          attendees: [%{"email" => "alice@example.com"}, %{"email" => "bob@example.com"}]
        })

      assert :ok = Orchestrator.schedule_event_update_notification(7, event)

      assert_received {:scheduled_event_update,
                       %{
                         user_id: 7,
                         event_uid: "event-uid-123",
                         integration_id: 42,
                         attendee_emails: ["alice@example.com", "bob@example.com"],
                         before_title: "Team Sync",
                         before_location: "Room 1",
                         before_description: "Agenda TBD",
                         before_start_at: ~U[2026-04-10 10:00:00Z],
                         before_end_at: ~U[2026-04-10 11:00:00Z]
                       }}
    end

    test "returns :ok even when the worker returns an error" do
      Application.put_env(:tymeslot, :email_worker_module, FailingUpdateWorker)

      event =
        original_event(%{attendees: [%{"email" => "carol@example.com"}]})

      assert :ok = Orchestrator.schedule_event_update_notification(3, event)
    end
  end

  describe "schedule_calendar_invitations/3" do
    test "returns :ok immediately for empty attendee list" do
      Application.put_env(:tymeslot, :email_worker_module, MockWorker)
      assert :ok = Orchestrator.schedule_calendar_invitations(1, [], event_details())
      refute_received {:scheduled_invitation, _}
    end

    test "schedules one job per attendee" do
      Application.put_env(:tymeslot, :email_worker_module, MockWorker)
      emails = ["a@example.com", "b@example.com", "c@example.com"]

      assert :ok = Orchestrator.schedule_calendar_invitations(1, emails, event_details())

      assert_received {:scheduled_invitation, %{attendee_email: "a@example.com"}}
      assert_received {:scheduled_invitation, %{attendee_email: "b@example.com"}}
      assert_received {:scheduled_invitation, %{attendee_email: "c@example.com"}}
    end

    test "continues scheduling when one attendee fails" do
      Application.put_env(:tymeslot, :email_worker_module, FailingWorker)
      emails = ["ok@example.com", "fail@example.com", "also-ok@example.com"]

      assert :ok = Orchestrator.schedule_calendar_invitations(1, emails, event_details())

      assert_received {:scheduled_invitation, %{attendee_email: "ok@example.com"}}
      assert_received {:scheduled_invitation, %{attendee_email: "also-ok@example.com"}}
      refute_received {:scheduled_invitation, %{attendee_email: "fail@example.com"}}
    end

    test "passes nil optional fields through" do
      Application.put_env(:tymeslot, :email_worker_module, MockWorker)

      assert :ok =
               Orchestrator.schedule_calendar_invitations(
                 42,
                 ["x@example.com"],
                 event_details(%{location: nil, description: nil})
               )

      assert_received {:scheduled_invitation,
                       %{
                         user_id: 42,
                         attendee_email: "x@example.com",
                         event_title: "Team Sync",
                         event_location: nil,
                         event_description: nil
                       }}
    end
  end
end
