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
    Logger.error("Authentication error: #{inspect(reason)}")

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
  def convert_to_boolean(_), do: false
end
