defmodule Tymeslot.EmailTesting.Testers.SystemEmails do
  @moduledoc """
  Test system-related email templates.
  """
  require Logger

  alias Tymeslot.Emails.EmailService

  @spec test_calendar_sync_error(String.t()) :: :ok | :error
  def test_calendar_sync_error(_email) do
    meeting = %{
      organizer_user_id: 1,
      start_time: DateTime.add(DateTime.utc_now(), 86_400, :second),
      duration: 30,
      location: "Video Call"
    }

    error_reason = "Unable to connect to calendar provider (test error)"

    case EmailService.send_calendar_sync_error(meeting, error_reason) do
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

  @spec test_contact_form(String.t()) :: :ok | :error
  def test_contact_form(email) do
    case EmailService.send_contact_form(
           "Test User",
           email,
           "Test Contact Form",
           "This is a test message from the debug script. Testing contact form functionality."
         ) do
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

  @spec test_individual(:calendar_sync_error | :contact_form, String.t()) :: :ok | :error
  def test_individual(:calendar_sync_error, email), do: test_calendar_sync_error(email)
  def test_individual(:contact_form, email), do: test_contact_form(email)
end
