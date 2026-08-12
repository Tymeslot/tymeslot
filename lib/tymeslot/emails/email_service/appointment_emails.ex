defmodule Tymeslot.Emails.EmailService.AppointmentEmails do
  @moduledoc "Appointment confirmation, reminder, and cancellation emails."

  require Logger

  alias Tymeslot.Emails.Delivery

  alias Tymeslot.Emails.Templates.{
    AppointmentCancellation,
    AppointmentConfirmation,
    AppointmentReminder,
    AppointmentRescheduled
  }

  @doc """
  Sends an appointment confirmation email to the organizer.
  """
  @spec send_appointment_confirmation_to_organizer(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_confirmation_to_organizer(organizer_email, appointment_details) do
    Delivery.deliver(
      AppointmentConfirmation.render(:organizer, organizer_email, appointment_details)
    )
  end

  @doc """
  Sends an appointment confirmation email to the attendee.
  """
  @spec send_appointment_confirmation_to_attendee(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_confirmation_to_attendee(attendee_email, appointment_details) do
    Delivery.deliver(
      AppointmentConfirmation.render(:attendee, attendee_email, appointment_details)
    )
  end

  @doc """
  Sends an appointment confirmation email to a meeting guest, with accept/decline
  RSVP buttons. `appointment_details` must carry `:guest_name`,
  `:guest_accept_url` and `:guest_decline_url`.
  """
  @spec send_guest_confirmation(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_guest_confirmation(guest_email, appointment_details) do
    Delivery.deliver(AppointmentConfirmation.render(:guest, guest_email, appointment_details))
  end

  @doc """
  Sends appointment confirmations to both organizer and attendee.
  """
  @spec send_appointment_confirmations(Tymeslot.Emails.EmailService.appointment_details()) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_appointment_confirmations(appointment_details) do
    Logger.info("Sending appointment confirmations",
      title: appointment_details[:title]
    )

    organizer_result =
      send_appointment_confirmation_to_organizer(
        appointment_details.organizer_email,
        appointment_details
      )

    attendee_result =
      send_appointment_confirmation_to_attendee(
        appointment_details.attendee_email,
        appointment_details
      )

    Logger.info("Appointment confirmations sent",
      organizer_sent: match?({:ok, _}, organizer_result),
      attendee_sent: match?({:ok, _}, attendee_result)
    )

    {organizer_result, attendee_result}
  end

  @doc """
  Sends a reschedule notice to the organizer.
  """
  @spec send_reschedule_email_to_organizer(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_reschedule_email_to_organizer(organizer_email, appointment_details) do
    Delivery.deliver(
      AppointmentRescheduled.render(:organizer, organizer_email, appointment_details)
    )
  end

  @doc """
  Sends a reschedule notice to the attendee.
  """
  @spec send_reschedule_email_to_attendee(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_reschedule_email_to_attendee(attendee_email, appointment_details) do
    Delivery.deliver(
      AppointmentRescheduled.render(:attendee, attendee_email, appointment_details)
    )
  end

  @doc """
  Sends reschedule notices to both organizer and attendee.

  The payload must be built by
  `Tymeslot.Notifications.ContentBuilder.build_reschedule_details/2`, which
  carries the previous slot alongside the new one.
  """
  @spec send_reschedule_emails(Tymeslot.Emails.EmailService.appointment_details()) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_reschedule_emails(appointment_details) do
    Logger.info("Sending reschedule notices",
      title: appointment_details[:title]
    )

    organizer_result =
      send_reschedule_email_to_organizer(
        appointment_details.organizer_email,
        appointment_details
      )

    attendee_result =
      send_reschedule_email_to_attendee(
        appointment_details.attendee_email,
        appointment_details
      )

    Logger.info("Reschedule notices sent",
      organizer_sent: match?({:ok, _}, organizer_result),
      attendee_sent: match?({:ok, _}, attendee_result)
    )

    {organizer_result, attendee_result}
  end

  @doc """
  Sends an appointment reminder email to the organizer.
  """
  @spec send_appointment_reminder_to_organizer(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_reminder_to_organizer(organizer_email, appointment_details) do
    Delivery.deliver(AppointmentReminder.render(:organizer, organizer_email, appointment_details))
  end

  @doc """
  Sends an appointment reminder email to the attendee.
  """
  @spec send_appointment_reminder_to_attendee(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_reminder_to_attendee(attendee_email, appointment_details) do
    Delivery.deliver(AppointmentReminder.render(:attendee, attendee_email, appointment_details))
  end

  @doc """
  Sends appointment reminders to both organizer and attendee.
  """
  @spec send_appointment_reminders(Tymeslot.Emails.EmailService.appointment_details()) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_appointment_reminders(appointment_details) do
    time_until =
      appointment_details[:time_until] || appointment_details[:reminder_time] || "30 minutes"

    send_appointment_reminders(appointment_details, time_until)
  end

  @doc """
  Sends appointment reminders to both organizer and attendee.
  Takes a time_until parameter (e.g., "30 minutes", "1 hour", "24 hours").
  """
  @spec send_appointment_reminders(
          Tymeslot.Emails.EmailService.appointment_details(),
          String.t()
        ) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_appointment_reminders(appointment_details, time_until) do
    Logger.info("Sending appointment reminders",
      title: appointment_details[:title],
      time_until: time_until
    )

    appointment_details_with_time = Map.put(appointment_details, :time_until, time_until)

    organizer_result =
      send_appointment_reminder_to_organizer(
        appointment_details.organizer_email,
        appointment_details_with_time
      )

    attendee_result =
      send_appointment_reminder_to_attendee(
        appointment_details.attendee_email,
        appointment_details_with_time
      )

    Logger.info("Appointment reminders sent",
      organizer_sent: match?({:ok, _}, organizer_result),
      attendee_sent: match?({:ok, _}, attendee_result)
    )

    {organizer_result, attendee_result}
  end

  @doc """
  Sends a cancellation email. Dispatches to organizer or attendee based on the email address.
  """
  @spec send_appointment_cancellation(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_cancellation(email, appointment_details) do
    if email == appointment_details.organizer_email do
      send_cancellation_email_to_organizer(email, appointment_details)
    else
      send_cancellation_email_to_attendee(email, appointment_details)
    end
  end

  @doc """
  Sends a cancellation email to the attendee.
  """
  @spec send_cancellation_email_to_attendee(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_cancellation_email_to_attendee(attendee_email, appointment_details) do
    Logger.info("Sending appointment cancellation to attendee",
      title: appointment_details[:title]
    )

    result =
      Delivery.deliver(
        AppointmentCancellation.render(:attendee, attendee_email, appointment_details)
      )

    Logger.info("Cancellation email sent to attendee",
      sent: match?({:ok, _}, result)
    )

    result
  end

  @doc """
  Sends a cancellation email to the organizer.
  """
  @spec send_cancellation_email_to_organizer(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_cancellation_email_to_organizer(organizer_email, appointment_details) do
    Logger.info("Sending appointment cancellation to organizer",
      title: appointment_details[:title]
    )

    result =
      Delivery.deliver(
        AppointmentCancellation.render(:organizer, organizer_email, appointment_details)
      )

    Logger.info("Cancellation email sent to organizer",
      sent: match?({:ok, _}, result)
    )

    result
  end

  @doc """
  Sends cancellation emails to both organizer and attendee.
  """
  @spec send_cancellation_emails(Tymeslot.Emails.EmailService.appointment_details()) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_cancellation_emails(appointment_details) do
    Logger.info("Sending appointment cancellations",
      title: appointment_details[:title]
    )

    organizer_result =
      send_cancellation_email_to_organizer(
        appointment_details.organizer_email,
        appointment_details
      )

    attendee_result =
      send_cancellation_email_to_attendee(
        appointment_details.attendee_email,
        appointment_details
      )

    Logger.info("Appointment cancellations sent",
      organizer_sent: match?({:ok, _}, organizer_result),
      attendee_sent: match?({:ok, _}, attendee_result)
    )

    {organizer_result, attendee_result}
  end
end
