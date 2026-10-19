defmodule Tymeslot.Mocks.Email do
  @moduledoc """
  Email service mocks. Stubs every notification type so tests can assert
  email delivery without sending real messages.

  See `Tymeslot.TestMocks` for the public API (`setup_email_mocks/1`).
  """

  import Mox

  @spec setup(keyword()) :: term()
  def setup(opts \\ []) do
    send_result = Keyword.get(opts, :send_result, :ok)

    Tymeslot.EmailServiceMock
    |> stub_meeting_emails(send_result)
    |> stub_account_emails(send_result)
  end

  defp stub_meeting_emails(mock, send_result) do
    mock
    |> stub(:send_appointment_confirmation_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_appointment_confirmation_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_guest_confirmation, fn _email, _details -> send_result end)
    |> stub(:send_seat_update_to_organizer, fn _variant, _email, _details -> send_result end)
    |> stub(:send_appointment_confirmations, fn _details -> {send_result, send_result} end)
    |> stub(:send_reschedule_email_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_reschedule_email_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_end_change_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_guest_end_change, fn _email, _details -> send_result end)
    |> stub(:send_end_change_to_organizer, fn _meeting, _email, _notice -> send_result end)
    |> stub(:send_appointment_reminder_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_appointment_reminder_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_appointment_reminders, fn _details, _time -> {send_result, send_result} end)
    |> stub(:send_cancellation_email_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_cancellation_email_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_calendar_sync_error, fn _meeting, _error -> send_result end)
    |> stub(:send_reschedule_request, fn _meeting -> send_result end)
  end

  defp stub_account_emails(mock, send_result) do
    mock
    |> stub(:send_email_verification, fn _user, _url -> send_result end)
    |> stub(:send_password_reset, fn _user, _url -> send_result end)
    |> stub(:send_no_password_to_reset, fn _user, _url -> send_result end)
    |> stub(:send_signup_attempt_notice, fn _user, _sign_in, _reset -> send_result end)
    |> stub(:send_account_deletion_notice, fn _recipient, _at, _url -> send_result end)
    |> stub(:send_social_signup_confirmation, fn _recipient, _provider, _url -> send_result end)
    |> stub(:send_email_change_verification, fn _user, _email, _url -> send_result end)
    |> stub(:send_email_change_notification, fn _user, _email -> send_result end)
    |> stub(:send_email_change_confirmations, fn _user, _old, _new ->
      {send_result, send_result}
    end)
  end
end
