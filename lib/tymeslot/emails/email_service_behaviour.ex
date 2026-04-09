defmodule Tymeslot.Emails.EmailServiceBehaviour do
  @moduledoc """
  Behavior for email service operations.
  """

  @type appointment_details :: Tymeslot.Emails.EmailService.appointment_details()
  @type user_map :: Tymeslot.Emails.EmailService.user_map()

  @callback send_appointment_confirmation_to_organizer(String.t(), appointment_details()) ::
              {:ok, any()} | {:error, any()}
  @callback send_appointment_confirmation_to_attendee(String.t(), appointment_details()) ::
              {:ok, any()} | {:error, any()}
  @callback send_appointment_confirmations(appointment_details()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_appointment_reminder_to_organizer(String.t(), appointment_details()) ::
              {:ok, any()} | {:error, any()}
  @callback send_appointment_reminder_to_attendee(String.t(), appointment_details()) ::
              {:ok, any()} | {:error, any()}
  @callback send_appointment_reminders(appointment_details()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_appointment_reminders(appointment_details(), String.t()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_appointment_cancellation(String.t(), appointment_details()) ::
              {:ok, any()} | {:error, any()}
  @callback send_cancellation_emails(appointment_details()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_calendar_sync_error(map(), any()) :: {:ok, any()} | {:error, any()}

  @callback send_email_verification(user_map(), String.t()) :: {:ok, any()} | {:error, any()}
  @callback send_password_reset(user_map(), String.t()) :: {:ok, any()} | {:error, any()}
  @callback send_email_change_verification(user_map(), String.t(), String.t()) ::
              {:ok, any()} | {:error, any()}
  @callback send_email_change_notification(user_map(), String.t()) ::
              {:ok, any()} | {:error, any()}
  @callback send_email_change_confirmations(user_map(), String.t(), String.t()) ::
              {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  @callback send_reschedule_request(map()) :: {:ok, any()} | {:error, any()}
  @callback send_integration_unhealthy_notification(
              user_map(),
              %{required(:provider) => atom(), optional(atom()) => term()},
              atom() | String.t()
            ) ::
              {:ok, any()} | {:error, any()}
  @callback send_external_booking_change(map(), String.t(), :deleted | :modified) ::
              {:ok, any()} | {:error, any()}
  @callback send_calendar_invitation(String.t(), map()) :: {:ok, any()} | {:error, any()}
  @callback send_event_update_notification(String.t(), map()) :: {:ok, any()} | {:error, any()}
  @callback send_admin_alert(
              recipient :: String.t(),
              category :: String.t(),
              severity :: :info | :warning | :error,
              message :: String.t(),
              metadata :: map()
            ) :: {:ok, any()} | {:error, any()}
end
