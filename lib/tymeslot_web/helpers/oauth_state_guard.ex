defmodule TymeslotWeb.Helpers.OAuthStateGuard do
  @moduledoc """
  Enforces that the user embedded in a signed OAuth `state` parameter matches
  the currently authenticated session user.

  Without this guard an attacker could initiate an OAuth flow on their own
  account (producing a signed state carrying the attacker's `user_id`), then
  trick an authenticated victim into completing the callback with a `code`
  issued for the victim's Google/Microsoft account — binding the victim's
  calendar/video account to the attacker's Tymeslot user.
  """

  require Logger

  alias Tymeslot.Integrations.Common.OAuth.State

  @type provider :: :google | :outlook
  @type failure_reason :: :invalid_state | :unauthenticated | :state_user_mismatch

  @sensitive_callback_keys ~w(code state id_token)

  @doc """
  Drops sensitive OAuth callback parameters from a map before logging.

  This is the canonical sensitive-params filter for OAuth callback logs. Both
  the calendar and video OAuth controllers use this function when logging
  unexpected or malformed callback parameter maps.
  """
  @spec redact_callback_params(map() | any()) :: map() | any()
  def redact_callback_params(params) when is_map(params),
    do: Map.drop(params, @sensitive_callback_keys)

  def redact_callback_params(other), do: other

  @spec enforce_user_match(Plug.Conn.t(), any(), provider()) :: :ok | {:error, failure_reason()}
  def enforce_user_match(conn, state, provider)
      when is_binary(state) and provider in [:google, :outlook] do
    case State.validate(state, provider_secret(provider)) do
      {:ok, %{user_id: state_user_id}} ->
        check_current_user(conn, state_user_id, provider)

      {:error, reason} ->
        Logger.warning("OAuth callback rejected: invalid or tampered state",
          provider: provider,
          reason: inspect(reason)
        )

        {:error, :invalid_state}
    end
  end

  def enforce_user_match(_conn, _state, provider) when provider in [:google, :outlook] do
    Logger.warning("OAuth callback rejected: state parameter missing or non-binary",
      provider: provider
    )

    {:error, :invalid_state}
  end

  defp check_current_user(conn, state_user_id, provider) do
    case conn.assigns[:current_user] do
      %{id: ^state_user_id} ->
        :ok

      %{id: current_id} ->
        Logger.warning("OAuth callback rejected: state/session user mismatch",
          provider: provider,
          state_user_id: state_user_id,
          current_user_id: current_id
        )

        {:error, :state_user_mismatch}

      _unauthenticated ->
        Logger.warning("OAuth callback rejected: no authenticated session",
          provider: provider,
          state_user_id: state_user_id
        )

        {:error, :unauthenticated}
    end
  end

  defp provider_secret(:google) do
    Application.get_env(:tymeslot, :google_oauth)[:state_secret] ||
      System.get_env("GOOGLE_STATE_SECRET") ||
      raise "Google OAuth state secret not configured"
  end

  defp provider_secret(:outlook) do
    Application.get_env(:tymeslot, :outlook_oauth)[:state_secret] ||
      System.get_env("OUTLOOK_STATE_SECRET") ||
      raise "Outlook OAuth state secret not configured"
  end
end
