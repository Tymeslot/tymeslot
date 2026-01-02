defmodule Tymeslot.Emails.EmailServiceBehaviour do
  @moduledoc """
  Behavior for email service operations.
  """

  @callback send_appointment_confirmation_to_organizer(String.t(), map()) ::
              {:ok, any()} | {:error, any()}
  @callback send_appointment_confirmation_to_attendee(String.t(), map()) ::
              {:ok, any()} | {:error, any()}
  @callback send_appointment_confirmations(map()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_appointment_reminder_to_organizer(String.t(), map()) ::
              {:ok, any()} | {:error, any()}
  @callback send_appointment_reminder_to_attendee(String.t(), map()) ::
              {:ok, any()} | {:error, any()}
  @callback send_appointment_reminders(map()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_appointment_reminders(map(), String.t()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_appointment_cancellation(String.t(), map()) :: {:ok, any()} | {:error, any()}
  @callback send_cancellation_emails(map()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_calendar_sync_error(any(), String.t()) :: {:ok, any()} | {:error, any()}

  @callback send_email_verification(map(), String.t()) :: {:ok, any()} | {:error, any()}
  @callback send_password_reset(map(), String.t()) :: {:ok, any()} | {:error, any()}
  @callback send_email_change_verification(map(), String.t(), String.t()) ::
              {:ok, any()} | {:error, any()}
  @callback send_email_change_notification(map(), String.t()) ::
              {:ok, any()} | {:error, any()}
  @callback send_email_change_confirmations(map(), String.t(), String.t()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_contact_form(String.t(), String.t(), String.t(), String.t()) ::
              {:ok, any()} | {:error, any()}
  @callback send_reschedule_request(map()) :: {:ok, any()} | {:error, any()}
end
