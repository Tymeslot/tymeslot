defmodule Tymeslot.Auth.AuthActions do
  @moduledoc """
  Handles authentication-related actions for auth UI components.
  Acts as a bridge between UI components and the Auth context.
  Extracts business logic from LiveView components.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Auth.{PasswordReset, Registration, Session, SocialAuthentication}
  alias Tymeslot.Security.AuthValidation
  alias TymeslotWeb.Helpers.ClientIP

  require Logger

  # OAuth Registration Actions

  @doc """
  Processes OAuth registration completion with profile data.
  """
  @spec complete_oauth_registration(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t(), String.t()} | {:error, String.t()}
  def complete_oauth_registration(params, socket) do
    auth_params = params["auth"] || %{}
    profile_params = params["profile"] || %{}

    temp_user = %{
      provider: auth_params["provider"],
      email: auth_params["email"],
      verified_email: auth_params["verified_email"] == "true",
      github_user_id: auth_params["github_user_id"],
      google_user_id: auth_params["google_user_id"]
    }

    with {:ok, converted_profile} <- convert_profile_params(profile_params),
         :ok <- SocialAuthentication.check_email_availability(auth_params["email"]),
         {:ok, user, message} <-
           SocialAuthentication.finalize_social_login_registration(
             auth_params,
             converted_profile,
             temp_user
           ),
         {:ok, updated_socket, _token} <- Session.create_session(socket, user) do
      {:ok, updated_socket, message}
    else
      # Handle 3-element error tuples from create_session
      {:error, :session_creation_failed, reason} ->
        {:error, reason}

      # Handle 3-element error tuples from finalize_social_login_registration
      {:error, error_type, reason}
      when error_type in [:registration_failed, :user_already_exists] ->
        {:error, reason}

      # Handle string errors from check_email_availability
      {:error, message} when is_binary(message) ->
        {:error, message}

      # Handle atom errors from convert_profile_params
      {:error, reason} when is_atom(reason) ->
        {:error, normalize_auth_error(reason)}
    end
  end

  # Registration Actions

  @doc """
  Handles user registration with email verification.
  """
  @spec register_user(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, atom(), String.t()} | {:error, String.t()}
  def register_user(user_params, socket) do
    case Registration.register_user(
           convert_terms_accepted(user_params),
           socket,
           calling_app: :auth
         ) do
      {:ok, _user, message} ->
        {:ok, :verify_email, message}

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
    ip = safe_client_ip(socket)

    case PasswordReset.initiate_reset(email, socket_or_conn: socket, ip: ip) do
      {:ok, :reset_initiated, message} ->
        {:ok, :reset_password_sent, message}

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
    case PasswordReset.reset_password(token, password, password_confirmation) do
      {:ok, _user, _message} ->
        {:ok, :password_reset_success,
         "Your password has been reset successfully. Please log in with your new password."}

      {:error, reason, _message} ->
        {:error, normalize_auth_error(reason)}
    end
  end

  # Validation Actions

  @doc """
  Validates signup form input.
  """
  @spec validate_signup_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_signup_input(params) do
    AuthValidation.validate_signup_input(params)
  end

  @doc """
  Validates login form input.
  """
  @spec validate_login_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_login_input(params) do
    AuthValidation.validate_login_input(params)
  end

  @doc """
  Validates password reset form input.
  """
  @spec validate_password_reset_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_password_reset_input(params) do
    AuthValidation.validate_password_reset_input(params)
  end

  @doc """
  Validates complete registration form data.
  """
  @spec validate_complete_registration(map(), map()) :: {:ok, map()} | {:error, map()}
  def validate_complete_registration(auth_params, profile_params) do
    validation_map = %{
      "email" => auth_params["email"],
      "full_name" => profile_params["full_name"],
      "terms_accepted" => auth_params["terms_accepted"]
    }

    AuthValidation.validate_signup_input(validation_map)
  end

  # State Management

  @doc """
  Updates socket with loading state.
  """
  @spec set_loading(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def set_loading(socket, loading) do
    assign(socket, :loading, loading)
  end

  @doc """
  Updates socket with error state.
  """
  @spec set_errors(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def set_errors(socket, errors) do
    socket
    |> assign(:errors, errors)
    |> assign(:loading, false)
  end

  @doc """
  Updates socket with form data.
  """
  @spec set_form_data(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def set_form_data(socket, form_data) do
    assign(socket, :form_data, form_data)
  end

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

  # Helper Functions

  @doc """
  Converts profile parameters from form data.
  """
  @spec convert_profile_params(map()) :: {:ok, map()} | {:error, atom()}
  def convert_profile_params(profile_params) do
    converted = SocialAuthentication.convert_to_atom_keys(profile_params)
    {:ok, converted}
  rescue
    ArgumentError ->
      Logger.error("Invalid atom key in profile params: #{inspect(profile_params)}")
      {:error, :invalid_profile_params}

    error ->
      Logger.error("Unexpected error converting profile params: #{inspect(error)}")
      {:error, :conversion_failed}
  end

  @doc """
  Converts terms_accepted string to boolean.
  """
  @spec convert_terms_accepted(map()) :: map()
  def convert_terms_accepted(user_params) do
    Map.update(user_params, "terms_accepted", false, fn
      "true" -> true
      true -> true
      _ -> false
    end)
  end

  # Private Functions

  defp normalize_auth_error(reason) do
    case reason do
      # Common errors
      :rate_limited -> "Too many attempts. Please try again later"
      :server_error -> "A server error occurred. Please try again"
      :invalid_input -> "Invalid input provided"
      :invalid_password -> "Invalid password"
      :invalid_token -> get_token_error_message(:invalid_token)
      :token_expired -> get_token_error_message(:token_expired)
      # OAuth registration errors
      :invalid_profile_params -> get_oauth_error_message(:invalid_profile_params)
      :conversion_failed -> get_oauth_error_message(:conversion_failed)
    end
  end

  defp safe_client_ip(socket_or_conn) do
    ClientIP.get(socket_or_conn)
  rescue
    _ -> nil
  end

  defp get_token_error_message(:invalid_token), do: "Invalid or expired token"

  defp get_token_error_message(:token_expired),
    do: "This link has expired. Please request a new one"

  defp get_oauth_error_message(:invalid_profile_params), do: "Invalid profile parameters provided"
  defp get_oauth_error_message(:conversion_failed), do: "Failed to process profile data"
end
