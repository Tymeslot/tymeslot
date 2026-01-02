defmodule Tymeslot.EmailTesting.Dispatcher do
  @moduledoc """
  Dispatch a single email template test to the appropriate tester module.
  """
  require Logger

  alias Tymeslot.EmailTesting.Testers.{Appointment, Auth, EmailChange, SystemEmails}

  @doc "Run a single template test by key"
  @spec test_individual_email(atom(), String.t(), DateTime.t() | nil) :: :ok | :error
  def test_individual_email(key, email, dt) do
    case key do
      key when key in [:appointment_confirmation_organizer, :appointment_confirmation_attendee] ->
        Appointment.test_individual(key, email, dt)

      key when key in [:appointment_reminder_organizer, :appointment_reminder_attendee] ->
        Appointment.test_individual(key, email, dt)

      key when key in [:appointment_cancellation_organizer, :appointment_cancellation_attendee] ->
        Appointment.test_individual(key, email, dt)

      key when key in [:email_verification, :password_reset] ->
        Auth.test_individual(key, email)

      key when key in [:calendar_sync_error, :contact_form] ->
        SystemEmails.test_individual(key, email)

      :reschedule_request ->
        Appointment.test_individual(:reschedule_request, email, dt)

      key
      when key in [
             :email_change_verification,
             :email_change_notification,
             :email_change_confirmed
           ] ->
        EmailChange.test_individual(key, email)

      _ ->
        IO.puts("❌ Unknown template")
        :error
    end
  rescue
    e ->
      IO.puts("❌ Exception")
      Logger.error("Error testing #{key}: #{inspect(e)}")
      :error
  end
end
