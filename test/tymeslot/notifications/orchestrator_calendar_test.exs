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
