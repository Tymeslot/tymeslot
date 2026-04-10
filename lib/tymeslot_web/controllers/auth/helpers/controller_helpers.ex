defmodule TymeslotWeb.AuthControllerHelpers do
  @moduledoc """
  Shared helper functions for authentication controllers.

  Provides common functionality used across all auth controllers including:
  - IP address extraction
  - Rate limiting logic
  - Common error handling patterns
  - Validation error formatting
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Tymeslot.Auth.AuthActions

  @doc """
  Handles rate limited response with flash message and redirect.

  ## Parameters
  - `conn`: The Plug connection
  - `message`: Optional custom error message
  - `redirect_path`: Path to redirect to (defaults to "/")
  """
  @spec handle_rate_limited(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def handle_rate_limited(
        conn,
        message \\ "Too many attempts. Please try again later.",
        redirect_path \\ "/"
      ) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: redirect_path)
  end

  @doc """
  Handles validation errors with consistent response pattern.

  ## Parameters
  - `conn`: The Plug connection
  - `errors`: Map of validation errors
  - `message`: Flash message to display
  - `render_function`: Function to render the form with errors
  """
  @spec handle_validation_error(Plug.Conn.t(), map(), String.t(), function()) :: Plug.Conn.t()
  def handle_validation_error(
        conn,
        errors,
        message \\ "Please correct the errors in the form.",
        render_function
      ) do
    conn
    |> put_status(200)
    |> put_flash(:error, message)
    |> render_function.(%{errors: errors})
  end

  @doc """
  Creates a form error response with render function.

  ## Parameters
  - `conn`: The Plug connection
  - `errors`: Map of validation errors
  - `message`: Flash message to display
  - `render_fn`: Anonymous function that takes conn and assigns and renders form

  ## Returns
  - Updated connection with error response
  """
  @spec form_error_with_render(
          Plug.Conn.t(),
          map(),
          String.t(),
          (Plug.Conn.t(), map() -> Plug.Conn.t())
        ) :: Plug.Conn.t()
  def form_error_with_render(conn, errors, message, render_fn) do
    updated_conn =
      conn
      |> put_status(200)
      |> put_flash(:error, message)

    render_fn.(updated_conn, %{errors: errors})
  end

  @doc """
  Formats validation errors into a readable string.

  ## Parameters
  - `errors`: Map of field errors

  ## Returns
  - Formatted error string
  """
  @spec format_validation_errors(map()) :: String.t()
  def format_validation_errors(errors) when is_map(errors) do
    Enum.map_join(errors, ". ", fn {field, message} ->
      field_name = field |> to_string() |> String.replace("_", " ") |> String.capitalize()
      "#{field_name} #{message}"
    end)
  end

  @doc """
  Handles generic errors with consistent logging and response.

  ## Parameters
  - `conn`: The Plug connection
  - `reason`: Error reason for logging
  - `user_message`: Message to show to user
  - `redirect_path`: Path to redirect to
  """
  @spec handle_generic_error(Plug.Conn.t(), any(), String.t(), String.t()) :: Plug.Conn.t()
  def handle_generic_error(conn, reason, user_message, redirect_path \\ "/") do
    require Logger
    Logger.error("Authentication error", reason: inspect(reason))

    conn
    |> put_flash(:error, user_message)
    |> redirect(to: redirect_path)
  end

  @doc """
  Converts boolean-like string values to actual booleans.
  Useful for form checkbox processing.

  ## Parameters
  - `value`: String value to convert

  ## Returns
  - Boolean value
  """
  @spec convert_to_boolean(String.t() | boolean()) :: boolean()
  def convert_to_boolean("true"), do: true
  def convert_to_boolean("on"), do: true
  def convert_to_boolean(true), do: true
  def convert_to_boolean(_other), do: false

  # -------------------------------------------------------------------
  # OAuth error formatting
  # -------------------------------------------------------------------

  @doc """
  Formats an OAuth error reason into a user-facing flash message.
  """
  @spec format_oauth_error_for_flash(any()) :: String.t()
  def format_oauth_error_for_flash(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [email: {"can't be blank", _opts}] ->
        "Email address is required to complete registration."

      [email: {message, _opts}] when is_binary(message) ->
        "Email #{message}. Please provide a valid email address."

      _other_errors ->
        "Registration failed due to validation errors. Please check your information and try again."
    end
  end

  def format_oauth_error_for_flash(:email_required),
    do: "Email address is required to complete registration."

  def format_oauth_error_for_flash(:invalid_email), do: "Please provide a valid email address."

  def format_oauth_error_for_flash(:terms_not_accepted),
    do: "You must accept the terms to continue."

  def format_oauth_error_for_flash(error_message) when is_binary(error_message), do: error_message

  @doc """
  Converts an OAuth error reason into a URL-safe query parameter value.
  """
  @spec format_oauth_error_for_params(any()) :: String.t()
  def format_oauth_error_for_params(%Ecto.Changeset{}), do: "validation_failed"
  def format_oauth_error_for_params(:email_required), do: "email_required"
  def format_oauth_error_for_params(:invalid_email), do: "invalid_email"
  def format_oauth_error_for_params(:terms_not_accepted), do: "terms_not_accepted"

  def format_oauth_error_for_params(error_message) when is_binary(error_message) do
    cond do
      error_message =~ "already registered" -> "email_taken"
      error_message =~ "Invalid email" -> "invalid_email"
      true -> "unknown_error"
    end
  end

  @doc """
  Renders a flash error and redirects for a generic OAuth failure reason.

  Handles known domain error atoms (`:user_creation_failed`, `:email_required`,
  etc.) and falls back to a generic message for unrecognised reasons.
  """
  @spec oauth_error_response(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def oauth_error_response(conn, reason, redirect_path) do
    error_message =
      case reason do
        %Ecto.Changeset{} = changeset ->
          format_oauth_error_for_flash(changeset)

        :user_creation_failed ->
          "Failed to create user account. Please try again."

        :invalid_oauth_data ->
          "Invalid OAuth data received. Please try again."

        :email_required ->
          "Email address is required to complete registration. Please provide your email address."

        :invalid_email ->
          "Please provide a valid email address."

        :terms_not_accepted ->
          "You must accept the terms to continue."

        :email_already_taken ->
          "This email address is already associated with another account. Please use a different email or sign in to your existing account."

        :registration_disabled ->
          AuthActions.registration_disabled_message()

        _unknown_error ->
          "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: redirect_path)
  end
end
