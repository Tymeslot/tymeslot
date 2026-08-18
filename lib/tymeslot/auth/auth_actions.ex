defmodule Tymeslot.Auth.AuthActions do
  @moduledoc """
  Handles authentication-related actions for auth UI components.
  Acts as a bridge between UI components and the Auth context.
  Extracts business logic from LiveView components.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Auth.{PasswordReset, Registration, Validation}
  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.Helpers.ClientIP

  @type signup_params :: Tymeslot.Auth.Validation.signup_params()

  @doc """
  Returns the user-facing message for when registration is disabled.
  """
  @spec registration_disabled_message() :: String.t()
  def registration_disabled_message,
    do: dgettext("auth", "Registration is currently disabled.")

  @doc """
  Returns the user-facing message for when password authentication is disabled.
  """
  @spec password_auth_disabled_message() :: String.t()
  def password_auth_disabled_message,
    do: dgettext("auth", "Password authentication is currently disabled.")

  # Registration Actions

  @doc """
  Handles user registration with email verification.
  """
  @spec register_user(signup_params(), Phoenix.LiveView.Socket.t()) ::
          {:ok, atom(), String.t()} | {:error, String.t()} | {:error, :field_errors, map()}
  def register_user(user_params, socket) do
    cond do
      not Config.password_auth_enabled?() -> {:error, password_auth_disabled_message()}
      not Config.registration_enabled?() -> {:error, registration_disabled_message()}
      true -> do_register_user(user_params, socket)
    end
  end

  defp do_register_user(user_params, socket) do
    converted_params = convert_terms_accepted(user_params)

    metadata = %{
      ip: ClientIP.get(socket),
      user_agent: ClientIP.get_user_agent(socket),
      source: "signup",
      terms_accepted: Map.get(converted_params, "terms_accepted")
    }

    case Registration.register_user(
           converted_params,
           socket,
           calling_app: :auth,
           metadata: metadata,
           # SignupSecurity.gate/2 already consumed a signup rate-limit token
           # for this attempt on the LiveView path; avoid double-counting it.
           rate_limit_checked: true
         ) do
      {:ok, _user, message} ->
        {:ok, :verify_email, message}

      {:error, :input, errors} when is_map(errors) ->
        {:error, :field_errors, errors}

      {:error, _reason, message} ->
        {:error, message}
    end
  end

  # Password Reset Actions

  @doc """
  Initiates password reset flow for the given email.
  """
  @spec request_password_reset(String.t(), term()) ::
          {:ok, atom(), String.t()} | {:error, String.t()}
  def request_password_reset(email, socket) do
    if Config.password_auth_enabled?() do
      do_request_password_reset(email, socket)
    else
      {:error, password_auth_disabled_message()}
    end
  end

  defp do_request_password_reset(email, socket) do
    ip = ClientIP.get(socket)

    case PasswordReset.initiate_reset(email, socket_or_conn: socket, ip: ip) do
      {:ok, :reset_initiated, message} ->
        {:ok, :reset_password_sent, message}

      {:error, :invalid_input, message} ->
        {:error, message}

      {:error, reason, _message} ->
        {:error, normalize_auth_error(reason)}
    end
  end

  @doc """
  Completes password reset with new password.
  """
  @spec reset_password(String.t(), String.t(), String.t(), term()) ::
          {:ok, atom(), String.t()} | {:error, String.t()}
  def reset_password(token, password, password_confirmation, _socket) do
    if Config.password_auth_enabled?() do
      do_reset_password(token, password, password_confirmation)
    else
      {:error, password_auth_disabled_message()}
    end
  end

  defp do_reset_password(token, password, password_confirmation) do
    case PasswordReset.reset_password(token, password, password_confirmation) do
      {:ok, _user, _message} ->
        {:ok, :password_reset_success,
         dgettext(
           "auth",
           "Your password has been reset successfully. Please log in with your new password."
         )}

      # The rejected password is the user's own input and they need to know
      # which rule it broke, so this one keeps its specific message rather
      # than collapsing to "Invalid input provided". Every other reason is
      # normalised, since those describe the token, not the password.
      {:error, :invalid_input, message} ->
        {:error, message}

      {:error, reason, _message} ->
        {:error, normalize_auth_error(reason)}
    end
  end

  # Validation Actions

  @doc """
  Validates signup form input.
  """
  @spec validate_signup_input(%{String.t() => term()}) ::
          {:ok, %{String.t() => term()}} | {:error, %{atom() => [String.t()]}}
  def validate_signup_input(params) do
    Validation.validate_signup_input(params)
  end

  @doc """
  Validates login form input.
  """
  @spec validate_login_input(%{String.t() => term()}) ::
          {:ok, %{String.t() => term()}} | {:error, %{atom() => String.t()}}
  def validate_login_input(params) do
    Validation.validate_login_input(params)
  end

  @doc """
  Validates password reset form input.
  """
  @spec validate_password_reset_input(%{String.t() => term()}) ::
          {:ok, %{String.t() => term()}} | {:error, %{atom() => [String.t()]}}
  def validate_password_reset_input(%{"email" => _email} = params) do
    Validation.validate_password_reset_input(params)
  end

  def validate_password_reset_input(
        %{"password" => _password, "password_confirmation" => _confirmation} = params
      ) do
    Validation.validate_new_password_input(params)
  end

  def validate_password_reset_input(_params),
    do: {:error, %{base: [dgettext("auth", "Invalid input format")]}}

  # State Management

  @doc """
  Transitions to a new authentication state.
  """
  @spec transition_state(term(), atom(), atom()) :: term()
  def transition_state(socket, new_state, previous_state) do
    socket
    |> assign(:current_state, new_state)
    |> assign(:previous_state, previous_state)
    |> assign(:loading, false)
  end

  @doc """
  Converts terms_accepted string to boolean.
  """
  @spec convert_terms_accepted(%{String.t() => term()}) :: %{String.t() => term()}
  def convert_terms_accepted(user_params) do
    Map.update(user_params, "terms_accepted", false, fn
      "true" -> true
      "on" -> true
      true -> true
      _other -> false
    end)
  end

  # Private Functions

  defp normalize_auth_error(reason) do
    case reason do
      :rate_limited -> dgettext("auth", "Too many attempts. Please try again later.")
      :server_error -> dgettext("auth", "A server error occurred. Please try again")
      :invalid_input -> dgettext("auth", "Invalid input provided")
      :invalid_password -> dgettext("auth", "Invalid password")
      :invalid_token -> get_token_error_message(:invalid_token)
      :token_expired -> get_token_error_message(:token_expired)
    end
  end

  defp get_token_error_message(:invalid_token),
    do: dgettext("auth", "Invalid or expired token")

  defp get_token_error_message(:token_expired),
    do: dgettext("auth", "This link has expired. Please request a new one")
end
