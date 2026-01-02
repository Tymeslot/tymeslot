defmodule Tymeslot.EmailTesting.Testers.EmailChange do
  @moduledoc """
  Test email change related email templates.
  """
  require Logger

  alias Tymeslot.Emails.EmailService

  @spec test_email_change_verification(String.t()) :: :ok | :error
  def test_email_change_verification(email) do
    user = %{id: 1, email: "old.email@example.com", name: "Test User"}
    new_email = email
    verification_url = "https://example.com/email-change/test-token"

    try do
      case EmailService.send_email_change_verification(user, new_email, verification_url) do
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

  @spec test_email_change_notification(String.t()) :: :ok | :error
  def test_email_change_notification(email) do
    user = %{id: 1, email: email, name: "Test User"}
    new_email = "new.test.email@example.com"

    try do
      case EmailService.send_email_change_notification(user, new_email) do
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

  @spec test_email_change_confirmed(String.t()) :: :ok | :error
  def test_email_change_confirmed(email) do
    user = %{id: 1, email: email, name: "Test User"}
    old_email = email
    new_email = email

    try do
      {old_result, new_result} =
        EmailService.send_email_change_confirmations(user, old_email, new_email)

      if match?({:ok, _}, old_result) and match?({:ok, _}, new_result) do
        IO.puts("✅")
        :ok
      else
        IO.puts("❌")

        Logger.error(
          "Failed confirmations - Old: #{inspect(old_result)}, New: #{inspect(new_result)}"
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

  @spec test_individual(atom(), String.t()) :: :ok | :error
  def test_individual(:email_change_verification, email),
    do: test_email_change_verification(email)

  def test_individual(:email_change_notification, email),
    do: test_email_change_notification(email)

  def test_individual(:email_change_confirmed, email), do: test_email_change_confirmed(email)
end
