defmodule Tymeslot.Emails.EmailActionsTest do
  use ExUnit.Case, async: true

  @moduletag :emails

  alias Tymeslot.Emails.EmailActions
  alias Tymeslot.Workers.EmailWorker

  # The names are stored in queued jobs. Renaming one strands every job queued
  # under the old name, so a change to this list must be deliberate.
  @names ~w(
    send_account_deletion_notice send_admin_alert send_admin_alert_digest
    send_booking_approval_nudge send_booking_request_emails send_booking_request_outcome
    send_calendar_invitation send_calendars_removed_notification send_cancellation_emails
    send_confirmation_emails send_email_change_confirmations send_email_change_notification
    send_email_change_verification send_email_verification send_end_change_emails
    send_event_update_notification send_guest_invitations send_integration_paused_notification
    send_integration_reauth_notification send_integration_unhealthy_notification
    send_no_password_to_reset send_password_reset send_poll_deadline_reminders
    send_poll_host_nudge send_reminder_emails send_reschedule_emails send_reschedule_request
    send_reschedule_request_expired send_seat_cancellation_emails send_seat_confirmation_emails
    send_seat_meeting_cancellation send_seat_reminder send_seat_reschedule_emails
    send_seat_reschedule_request send_signup_attempt_notice send_social_signup_confirmation
    send_video_room_creation_error_notification
  )

  test "every action keeps the name jobs are already queued under" do
    assert Enum.sort(EmailActions.names()) == Enum.sort(@names)
  end

  test "every action names a handler that exists, with the arity its tag says" do
    missing =
      for name <- EmailActions.names(),
          {:ok, handler} = EmailActions.handler(name),
          not exported?(handler),
          do: {name, handler}

    assert missing == []
  end

  test "every action requires at least one arg besides its name" do
    assert Enum.reject(
             EmailActions.names(),
             &match?({:ok, [_ | _]}, EmailActions.required_fields(&1))
           ) ==
             []
  end

  test "every per-seat action is a registered action" do
    seats =
      ~w(seat_confirmation seat_cancellation seat_meeting_cancellation seat_reschedule
         seat_reschedule_request seat_reminder)a

    assert Enum.reject(seats, &(EmailActions.seat_action(&1) in EmailActions.names())) == []
  end

  describe "EmailWorker.new/2" do
    test "builds a job for a known action with its required args" do
      assert %{valid?: true} =
               EmailWorker.new(%{"action" => "send_confirmation_emails", "meeting_id" => "m"})
    end

    test "refuses an action no handler knows, so a typo fails the insert" do
      changeset = EmailWorker.new(%{"action" => "send_confirmaton_emails", "meeting_id" => "m"})

      assert {"unknown email action: \"send_confirmaton_emails\"", _opts} =
               changeset.errors[:args]
    end

    test "refuses a job missing a required arg" do
      changeset = EmailWorker.new(%{"action" => "send_reminder_emails", "meeting_id" => "m"})

      assert {"missing required fields: reminder_value, reminder_unit", _opts} =
               changeset.errors[:args]
    end

    test "refuses args without an action" do
      assert {"missing an action", _opts} = EmailWorker.new(%{"meeting_id" => "m"}).errors[:args]
    end

    # Some args are present but nil on purpose (an all-day invitation has no
    # start time); the check is for the key.
    test "accepts a required arg that is present but nil" do
      assert %{valid?: true} =
               EmailWorker.new(%{"action" => "send_confirmation_emails", "meeting_id" => nil})
    end
  end

  defp exported?({module, fun}), do: loaded_export?(module, fun, 1)
  defp exported?({module, fun, :with_job_id}), do: loaded_export?(module, fun, 2)

  defp loaded_export?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
