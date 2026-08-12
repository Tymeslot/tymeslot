defmodule Tymeslot.Notifications.OrchestratorLifecycleTest do
  use Tymeslot.DataCase, async: false

  @moduletag :notifications

  import Tymeslot.Factory

  alias Tymeslot.Notifications.Orchestrator

  defmodule SuccessWorker do
    @spec schedule_cancellation_emails(term()) :: :ok
    def schedule_cancellation_emails(meeting_id) do
      send(self(), {:scheduled_cancellation, meeting_id})
      :ok
    end
  end

  defmodule FailingWorker do
    @spec schedule_cancellation_emails(term()) :: {:error, String.t()}
    def schedule_cancellation_emails(_meeting_id) do
      {:error, "queue down"}
    end
  end

  defmodule SuccessEmailService do
    @spec send_reschedule_emails(map()) :: {{:ok, term()}, {:ok, term()}}
    def send_reschedule_emails(content) do
      send(self(), {:reschedule_emails_sent, content})
      {{:ok, :organizer_email}, {:ok, :attendee_email}}
    end
  end

  defmodule PartialFailureEmailService do
    @spec send_reschedule_emails(map()) :: {{:ok, term()}, {:error, term()}}
    def send_reschedule_emails(content) do
      send(self(), {:reschedule_emails_partial, content})
      {{:ok, :organizer_email}, {:error, :smtp_down}}
    end
  end

  setup do
    original_worker = Application.get_env(:tymeslot, :email_worker_module)
    original_service = Application.get_env(:tymeslot, :email_service_module)

    on_exit(fn ->
      restore_env(:email_worker_module, original_worker)
      restore_env(:email_service_module, original_service)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)

  defp meeting_for_lifecycle(attrs \\ %{}, builder \\ &insert/2) do
    user = insert(:user)
    insert(:profile, user: user, timezone: "Europe/London")

    builder.(
      :meeting,
      Map.merge(
        %{
          organizer_user_id: user.id,
          organizer_name: "Alice",
          organizer_email: "alice@example.com",
          attendee_name: "Bob",
          attendee_email: "bob@example.com",
          attendee_timezone: "America/New_York"
        },
        attrs
      )
    )
  end

  describe "send_cancellation_notifications/1" do
    test "schedules the cancellation job for the meeting" do
      Application.put_env(:tymeslot, :email_worker_module, SuccessWorker)
      meeting = meeting_for_lifecycle()

      assert {:ok, :cancellation_scheduled} =
               Orchestrator.send_cancellation_notifications(meeting)

      assert_received {:scheduled_cancellation, meeting_id}
      assert meeting_id == meeting.id
    end

    test "returns an error when recipients are incomplete" do
      Application.put_env(:tymeslot, :email_worker_module, SuccessWorker)
      meeting = meeting_for_lifecycle(%{organizer_email: nil}, &build/2)

      assert {:error, message} = Orchestrator.send_cancellation_notifications(meeting)
      assert message =~ "organizer"
      refute_received {:scheduled_cancellation, _}
    end

    test "propagates worker failure" do
      Application.put_env(:tymeslot, :email_worker_module, FailingWorker)
      meeting = meeting_for_lifecycle()

      assert {:error, "queue down"} =
               Orchestrator.send_cancellation_notifications(meeting)
    end
  end

  describe "send_reschedule_notifications/2" do
    test "delivers reschedule emails to both parties with original-meeting context" do
      Application.put_env(:tymeslot, :email_service_module, SuccessEmailService)

      original =
        meeting_for_lifecycle(%{
          start_time: ~U[2026-06-01 10:00:00Z],
          end_time: ~U[2026-06-01 11:00:00Z]
        })

      updated = %{
        original
        | start_time: ~U[2026-06-02 14:00:00Z],
          end_time: ~U[2026-06-02 15:00:00Z]
      }

      assert {:ok, :reschedules_sent} =
               Orchestrator.send_reschedule_notifications(updated, original)

      assert_received {:reschedule_emails_sent, content}
      assert content.organizer_email == "alice@example.com"
      assert content.attendee_email == "bob@example.com"
      assert content.is_rescheduled == true
      assert content.original_start_time == ~U[2026-06-01 10:00:00Z]
      assert content.start_time == ~U[2026-06-02 14:00:00Z]
    end

    test "reports partial failure when one recipient delivery fails" do
      Application.put_env(:tymeslot, :email_service_module, PartialFailureEmailService)
      meeting = meeting_for_lifecycle()

      assert {:ok, :reschedules_partially_sent} =
               Orchestrator.send_reschedule_notifications(meeting, meeting)

      assert_received {:reschedule_emails_partial, _content}
    end

    test "does not deliver when recipients are incomplete" do
      Application.put_env(:tymeslot, :email_service_module, SuccessEmailService)
      meeting = meeting_for_lifecycle(%{attendee_email: nil}, &build/2)

      assert {:error, _reason} = Orchestrator.send_reschedule_notifications(meeting, meeting)
      refute_received {:reschedule_emails_sent, _}
    end
  end
end
