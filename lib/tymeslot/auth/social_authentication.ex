defmodule Tymeslot.Auth.SocialAuthentication do
  @moduledoc """
  Handles social authentication helpers.
  """

  alias Tymeslot.Infrastructure.Config

  require Logger

  @doc """
  Checks if an email is available for registration.

  Returns `:ok` if available, `{:error, :email_already_taken}` when an account
  already uses the address, or `{:error, :invalid_email}` for a non-string
  value. The reasons are atoms so that the web layer, not the domain, decides
  how to phrase them in the visitor's locale.
  """
  @spec check_email_availability(term()) :: :ok | {:error, :email_already_taken | :invalid_email}
  def check_email_availability(email) when is_binary(email) do
    case user_queries_module().get_user_by_email(email) do
      {:error, :not_found} ->
        :ok

      {:ok, _user} ->
        Logger.warning("Email already registered")
        {:error, :email_already_taken}
    end
  end

  def check_email_availability(other) do
    Logger.warning("Invalid email format", value: inspect(other))
    {:error, :invalid_email}
  end

  defp user_queries_module do
    Config.user_queries_module()
  end
end
