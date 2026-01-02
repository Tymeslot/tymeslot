defmodule Tymeslot.EmailTesting.Testers.Auth do
  @moduledoc """
  Test user authentication-related email templates.
  """
  require Logger

  alias Tymeslot.Emails.EmailService

  @spec test_email_verification(String.t()) :: :ok | :error
  def test_email_verification(email) do
    user = %{email: email, name: "Test User"}
    verification_url = "https://example.com/verify/test-token"

    try do
      case EmailService.send_email_verification(user, verification_url) do
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

  @spec test_password_reset(String.t()) :: :ok | :error
  def test_password_reset(email) do
    user = %{email: email, name: "Test User"}
    reset_url = "https://example.com/reset/test-token"

    try do
      case EmailService.send_password_reset(user, reset_url) do
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

  @spec test_individual(:email_verification | :password_reset, String.t()) :: :ok | :error
  def test_individual(:email_verification, email), do: test_email_verification(email)
  def test_individual(:password_reset, email), do: test_password_reset(email)
end
