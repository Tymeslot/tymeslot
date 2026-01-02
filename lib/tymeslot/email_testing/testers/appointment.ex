defmodule Tymeslot.EmailTesting.Testers.Appointment do
  @moduledoc """
  Test appointment-related email templates.
  """
  require Logger
  alias Tymeslot.DatabaseSchemas.MeetingSchema, as: Meeting
  alias Tymeslot.Emails.EmailService
  alias Tymeslot.EmailTesting.Helpers

  # 1-2. Both confirmations
  @spec test_confirmations_both(String.t(), DateTime.t()) :: :ok | :error
  def test_confirmations_both(email, start_time) do
    IO.write("📧 1-2. Appointment Confirmations (Organizer + Attendee)... ")

    appointment_details = Helpers.build_appointment_details(email, start_time)

    try do
      {organizer_result, attendee_result} =
        EmailService.send_appointment_confirmations(appointment_details)

      if match?({:ok, _}, organizer_result) and match?({:ok, _}, attendee_result) do
        IO.puts("✅")
        :ok
      else
        IO.puts("❌")

        Logger.error(
          "Failed confirmations - Organizer: #{inspect(organizer_result)}, Attendee: #{inspect(attendee_result)}"
        )

        :error
      end
    rescue
      e ->
        IO.puts("❌ Exception")
        Logger.error("Error: #{inspect(e)}")
        :error
    end
  end

  # 3-4. Both reminders
  @spec test_reminders_both(String.t(), DateTime.t()) :: :ok | :error
  def test_reminders_both(email, start_time) do
    IO.write("📧 3-4. Appointment Reminders (Organizer + Attendee)... ")

    appointment_details =
      Map.merge(
        Helpers.build_appointment_details(email, start_time),
        %{time_until: "24 hours", time_until_friendly: "in 24 hours"}
      )

    try do
      {organizer_result, attendee_result} =
        EmailService.send_appointment_reminders(appointment_details)

      if match?({:ok, _}, organizer_result) and match?({:ok, _}, attendee_result) do
        IO.puts("✅")
        :ok
      else
        IO.puts("❌")

        Logger.error(
          "Failed reminders - Organizer: #{inspect(organizer_result)}, Attendee: #{inspect(attendee_result)}"
        )

        :error
      end
    rescue
      e ->
        IO.puts("❌ Exception")
        Logger.error("Error: #{inspect(e)}")
        :error
    end
  end

  # 5-6. Both cancellations
  @spec test_cancellations_both(String.t(), DateTime.t()) :: :ok | :error
  def test_cancellations_both(email, start_time) do
    IO.write("📧 5-6. Appointment Cancellations (Organizer + Attendee)... ")

    appointment_details =
      Map.put(
        Helpers.build_appointment_details(email, start_time),
        :cancellation_reason,
        "Testing cancellation emails"
      )

    try do
      {organizer_result, attendee_result} =
        EmailService.send_cancellation_emails(appointment_details)

      if match?({:ok, _}, organizer_result) and match?({:ok, _}, attendee_result) do
        IO.puts("✅")
        :ok
      else
        IO.puts("❌")

        Logger.error(
          "Failed cancellations - Organizer: #{inspect(organizer_result)}, Attendee: #{inspect(attendee_result)}"
        )

        :error
      end
    rescue
      e ->
        IO.puts("❌ Exception")
        Logger.error("Error: #{inspect(e)}")
        :error
    end
  end

  # Individual appointment tests
  @spec test_individual(atom(), String.t(), DateTime.t()) :: :ok | :error
  def test_individual(:appointment_confirmation_organizer, email, start_time),
    do: confirmation_organizer(email, start_time)

  def test_individual(:appointment_confirmation_attendee, email, start_time),
    do: confirmation_attendee(email, start_time)

  def test_individual(:appointment_reminder_organizer, email, start_time),
    do: reminder_organizer(email, start_time)

  def test_individual(:appointment_reminder_attendee, email, start_time),
    do: reminder_attendee(email, start_time)

  def test_individual(:appointment_cancellation_organizer, email, start_time),
    do: cancellation_organizer(email, start_time)

  def test_individual(:appointment_cancellation_attendee, email, start_time),
    do: cancellation_attendee(email, start_time)

  def test_individual(:reschedule_request, email, start_time),
    do: test_reschedule_request(email, start_time)

  defp confirmation_organizer(email, start_time) do
    details = Helpers.build_appointment_details(email, start_time)

    case EmailService.send_appointment_confirmation_to_organizer(email, details) do
      {:ok, _} ->
        IO.puts("✅")
        :ok

      {:error, reason} ->
        IO.puts("❌")
        Logger.error("Failed: #{inspect(reason)}")
        :error
    end
  end

  defp confirmation_attendee(email, start_time) do
    details = Helpers.build_appointment_details(email, start_time)

    case EmailService.send_appointment_confirmation_to_attendee(email, details) do
      {:ok, _} ->
        IO.puts("✅")
        :ok

      {:error, reason} ->
        IO.puts("❌")
        Logger.error("Failed: #{inspect(reason)}")
        :error
    end
  end

  defp reminder_organizer(email, start_time) do
    details = Helpers.build_appointment_details(email, start_time)

    case EmailService.send_appointment_reminder_to_organizer(email, details) do
      {:ok, _} ->
        IO.puts("✅")
        :ok

      {:error, reason} ->
        IO.puts("❌")
        Logger.error("Failed: #{inspect(reason)}")
        :error
    end
  end

  defp reminder_attendee(email, start_time) do
    details = Helpers.build_appointment_details(email, start_time)

    case EmailService.send_appointment_reminder_to_attendee(email, details) do
      {:ok, _} ->
        IO.puts("✅")
        :ok

      {:error, reason} ->
        IO.puts("❌")
        Logger.error("Failed: #{inspect(reason)}")
        :error
    end
  end

  defp cancellation_organizer(email, start_time) do
    details = Helpers.build_appointment_details(email, start_time)

    case EmailService.send_cancellation_email_to_organizer(email, details) do
      {:ok, _} ->
        IO.puts("✅")
        :ok

      {:error, reason} ->
        IO.puts("❌")
        Logger.error("Failed: #{inspect(reason)}")
        :error
    end
  end

  defp cancellation_attendee(email, start_time) do
    details = Helpers.build_appointment_details(email, start_time)

    case EmailService.send_cancellation_email_to_attendee(email, details) do
      {:ok, _} ->
        IO.puts("✅")
        :ok

      {:error, reason} ->
        IO.puts("❌")
        Logger.error("Failed: #{inspect(reason)}")
        :error
    end
  end

  @spec test_reschedule_request(String.t(), DateTime.t()) :: :ok | :error
  def test_reschedule_request(email, start_time) do
    meeting =
      struct(Meeting, %{
        id: "test-#{:rand.uniform(10000)}",
        organizer_name: "Test Organizer",
        organizer_email: email,
        attendee_name: "Test Attendee",
        attendee_email: email,
        attendee_timezone: "America/New_York",
        title: "Test Meeting",
        start_time: start_time,
        duration: 30,
        location: "Video Call",
        meeting_type: "Debug Test",
        reschedule_url: "https://example.com/reschedule/test-token",
        cancel_url: "https://example.com/cancel/test-token",
        status: "pending"
      })

    try do
      case EmailService.send_reschedule_request(meeting) do
        {:ok, _} ->
          IO.puts("✅")
          :ok

        {:error, reason} ->
          IO.puts("❌")
          Logger.error("Failed: #{inspect(reason)}")
          :error
      end
    rescue
      e ->
        IO.puts("❌ Exception")
        Logger.error("Error: #{inspect(e)}")
        :error
    end
  end
end
