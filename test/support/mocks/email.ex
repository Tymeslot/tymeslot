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
    |> stub(:send_appointment_confirmation_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_appointment_confirmation_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_appointment_confirmations, fn _details -> {send_result, send_result} end)
    |> stub(:send_appointment_reminder_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_appointment_reminder_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_appointment_reminders, fn _details -> {send_result, send_result} end)
    |> stub(:send_appointment_reminders, fn _details, _time -> {send_result, send_result} end)
    |> stub(:send_appointment_cancellation, fn _email, _details -> send_result end)
    |> stub(:send_cancellation_emails, fn _details -> {send_result, send_result} end)
    |> stub(:send_calendar_sync_error, fn _meeting, _error -> send_result end)
    |> stub(:send_email_verification, fn _user, _url -> send_result end)
    |> stub(:send_password_reset, fn _user, _url -> send_result end)
    |> stub(:send_email_change_verification, fn _user, _email, _url -> send_result end)
    |> stub(:send_email_change_notification, fn _user, _email -> send_result end)
    |> stub(:send_email_change_confirmations, fn _user, _old, _new ->
      {send_result, send_result}
    end)
    |> stub(:send_reschedule_request, fn _meeting -> send_result end)
  end
end
