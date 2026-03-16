defmodule Tymeslot.Auth.SocialAuthentication do
  @moduledoc """
  Handles social authentication helpers.
  """

  alias Tymeslot.Infrastructure.Config

  require Logger

  @doc """
  Checks if an email is available for registration.
  Returns :ok if available, {:error, reason} otherwise.
  """
  @spec check_email_availability(String.t()) :: :ok | {:error, String.t()}
  def check_email_availability(email) when is_binary(email) do
    case user_queries_module().get_user_by_email(email) do
      {:error, :not_found} ->
        :ok

      {:ok, _user} ->
        Logger.warning("Email already registered")
        {:error, "This email is already registered. Please use a different email address."}
    end
  end

  def check_email_availability(other) do
    Logger.warning("Invalid email format", value: inspect(other))
    {:error, "Invalid email format"}
  end

  defp user_queries_module do
    Config.user_queries_module()
  end
end
