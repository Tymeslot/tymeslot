defmodule Tymeslot.Auth.OAuth.FlowHandler do
  @moduledoc """
  Orchestrates the OAuth callback flow, returning tagged result tuples.

  All presentation concerns (flash messages, HTTP redirects) are the
  responsibility of the calling controller.
  """

  require Logger

  alias Tymeslot.Auth.OAuth.{Client, HelperBehaviour, State, URLs, UserProcessor, UserRegistration}
  alias Tymeslot.Auth.Session
  alias Tymeslot.Infrastructure.Config

  @type provider :: :github | :google | :oauth
  @type flow_result :: HelperBehaviour.flow_result()

  @doc """
  Handles the complete OAuth callback flow.

  Returns a tagged tuple describing the outcome. Callers are responsible for
  translating each variant into flash messages and HTTP redirects:

  - `{:ok, conn, provider}` — session established; redirect to success path.
  - `{:registration_required, conn, provider, params}` — new user; redirect to
    the registration form, passing `params` as query string.
  - `{:error, :invalid_state, conn}` — CSRF state mismatch.
  - `{:error, :oauth_error, provider, conn}` — OAuth2 protocol error.
  - `{:error, :general_error, provider, conn}` — unexpected error during token
    exchange or user processing.
  - `{:error, :session_failed, provider, conn}` — OAuth succeeded but session
    creation failed.
  """
  @spec handle_oauth_callback(Plug.Conn.t(), map()) :: flow_result()
  def handle_oauth_callback(conn, %{code: code, state: state, provider: provider}) do
    with {:ok, conn} <- validate_oauth_state(conn, state),
         {:ok, conn, user} <- process_oauth_response(conn, code, provider) do
      complete_oauth_flow(conn, user, provider)
    end
  end

  # Private helpers

  defp validate_oauth_state(conn, state) do
    case State.validate_state(conn, state) do
      :ok ->
        {:ok, State.clear_oauth_state(conn)}

      {:error, :invalid_state} ->
        Logger.warning("OAuth callback received with invalid or missing state parameter")
        {:error, :invalid_state, conn}
    end
  end

  defp process_oauth_response(conn, code, provider) do
    full_callback_url = URLs.callback_url(conn, URLs.callback_path(provider))
    client = Client.build(provider, full_callback_url, "")

    with {:ok, client} <- Client.exchange_code_for_token(client, code),
         {:ok, user_info} <- Client.get_user_info(client, provider),
         {:ok, user} <- UserProcessor.process_user(provider, user_info) do
      enhanced_user = UserProcessor.enhance_user_data(provider, user, client)
      {:ok, conn, enhanced_user}
    else
      {:error, %OAuth2.Error{} = error} ->
        Logger.error("OAuth error", provider: to_string(provider), error: inspect(error))
        {:error, :oauth_error, provider, conn}

      {:error, reason} ->
        Logger.error("OAuth authentication error",
          provider: to_string(provider),
          reason: inspect(reason)
        )

        {:error, :general_error, provider, conn}
    end
  end

  defp complete_oauth_flow(conn, user, provider) do
    case UserRegistration.find_existing_user(provider, user) do
      {:ok, existing_user} ->
        create_user_session(conn, existing_user, provider)

      {:error, :not_found} ->
        handle_new_user_registration(conn, provider, user)
    end
  end

  defp create_user_session(conn, user, provider) do
    case Session.create_session(conn, %{id: user.id}) do
      {:ok, conn, _token} ->
        {:ok, conn, provider}

      {:error, reason, _message} ->
        Logger.error("Failed to create session after OAuth auth",
          provider: to_string(provider),
          reason: inspect(reason)
        )

        {:error, :session_failed, provider, conn}
    end
  end

  defp handle_new_user_registration(conn, provider, user) do
    if Config.registration_enabled?() do
      case UserRegistration.check_oauth_requirements(provider, user) do
        {:missing, missing_fields} ->
          {:registration_required, conn, provider, build_modal_params(provider, user, missing_fields)}

        :complete ->
          # All required fields are present but no account exists yet. Route the
          # user through the registration form for explicit confirmation rather
          # than silently auto-creating an account.
          Logger.warning(
            "OAuth user data is complete but no account found; routing to registration",
            provider: to_string(provider)
          )

          {:registration_required, conn, provider, build_modal_params(provider, user, [])}
      end
    else
      {:error, :registration_disabled, provider, conn}
    end
  end

  defp build_modal_params(provider, user, missing_fields) do
    email_from_provider = user.email != nil and String.trim(user.email) != ""

    %{
      "auth" => "oauth_complete",
      "oauth_provider" => to_string(provider),
      "oauth_missing" => Enum.join(missing_fields, ","),
      "oauth_email" => user.email || "",
      "oauth_verified" => to_string(user.is_verified),
      "oauth_email_from_provider" => to_string(email_from_provider),
      "oauth_#{provider}_id" => to_string(Map.get(user, String.to_existing_atom("#{provider}_user_id")) || ""),
      "oauth_name" => user.name || ""
    }
  end
end
