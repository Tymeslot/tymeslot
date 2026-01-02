defmodule Tymeslot.Integrations.Common.ErrorHandler do
  @moduledoc """
  Standardized error handling for all integration modules.

  This module provides consistent error formatting, logging, and handling patterns
  across all calendar and video integration providers.
  """

  require Logger

  alias Tymeslot.Infrastructure.Common.ErrorTranslator
  alias Tymeslot.Infrastructure.Logging.Redactor

  @doc """
  Normalizes error tuples to a consistent format.

  Converts various error tuple formats to the standard `{:error, reason}` format.

  ## Examples

      iex> normalize_error({:error, :timeout, "Request timed out"})
      {:error, "Request timed out"}

      iex> normalize_error({:error, "Simple error"})
      {:error, "Simple error"}

      iex> normalize_error({:ok, "Success"})
      {:ok, "Success"}
  """
  @spec normalize_error({:error, any(), any()}) :: {:error, any()}
  @spec normalize_error({:error, any()}) :: {:error, any()}
  @spec normalize_error({:ok, any()}) :: {:ok, any()}
  @spec normalize_error(any()) :: any()
  def normalize_error({:error, _type, reason}), do: {:error, reason}
  def normalize_error({:error, reason}), do: {:error, reason}
  def normalize_error({:ok, result}), do: {:ok, result}
  def normalize_error(other), do: other

  @doc """
  Wraps a function call with standardized error handling and logging.

  This function executes the provided function and handles any errors
  with consistent logging and error formatting.

  ## Options

    * `:operation` - A string describing the operation being performed (for logging)
    * `:provider` - The provider name (for logging context)
    * `:log_level` - The log level to use for errors (default: :error)
    * `:suppress_errors` - List of error reasons to suppress from logging

  ## Examples

      handle_with_logging(fn ->
        SomeAPI.call()
      end, operation: "fetch calendar events", provider: "google")
  """
  @spec handle_with_logging((-> any()), keyword()) :: any()
  def handle_with_logging(fun, opts \\ []) when is_function(fun, 0) do
    operation = Keyword.get(opts, :operation, "unknown operation")
    provider = Keyword.get(opts, :provider, "unknown provider")
    log_level = Keyword.get(opts, :log_level, :error)
    suppress_errors = Keyword.get(opts, :suppress_errors, [])

    try do
      case fun.() do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = error ->
          unless reason in suppress_errors do
            log_error(log_level, operation, provider, reason)
          end

          error

        {:error, _type, reason} = error ->
          normalized_error = normalize_error(error)

          unless reason in suppress_errors do
            log_error(log_level, operation, provider, reason)
          end

          normalized_error

        other ->
          Logger.warning(
            "Unexpected return value from #{operation} (#{provider}): #{inspect(other)}"
          )

          other
      end
    rescue
      exception ->
        error_reason = Exception.message(exception)
        log_error(log_level, operation, provider, error_reason, exception)
        {:error, error_reason}
    end
  end

  @doc """
  Creates a standardized error message for integration failures.

  ## Examples

      iex> format_integration_error("google", "authentication", "invalid token")
      "Google integration failed during authentication: invalid token"
  """
  @spec format_integration_error(String.t(), String.t(), String.t()) :: String.t()
  def format_integration_error(provider, operation, reason) do
    provider_name = String.capitalize(provider)
    "#{provider_name} integration failed during #{operation}: #{reason}"
  end

  @doc """
  Handles integration errors with user-friendly translations.

  Returns a tuple with the error atom/message and a user-friendly translation.
  """
  @spec handle_integration_error(any(), String.t(), map()) :: {:error, any(), any()}
  def handle_integration_error(error, provider, context \\ %{}) do
    translated = ErrorTranslator.translate_error(error, provider, context)

    # Log the technical error
    Logger.error("Integration error",
      provider: provider,
      error: Redactor.redact(error),
      category: translated.category,
      severity: translated.severity
    )

    # Return both technical and user-friendly versions
    {:error, error, translated}
  end

  @doc """
  Wraps an integration operation with comprehensive error handling.
  """
  @spec with_error_handling(String.t(), String.t(), (-> any())) ::
          {:ok, any()} | {:error, any(), any()} | any()
  def with_error_handling(provider, operation, fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        handle_integration_error(reason, provider, %{operation: operation})

      other ->
        other
    end
  rescue
    exception ->
      error = Exception.message(exception)

      handle_integration_error(error, provider, %{
        operation: operation,
        exception_type: exception.__struct__
      })
  end

  @doc """
  Handles database operation errors with consistent formatting.

  Converts Ecto changeset errors and other database errors to user-friendly messages.
  """
  @spec handle_database_error({:error, Ecto.Changeset.t()}) :: {:error, String.t()}
  def handle_database_error({:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
        "#{field}: #{message}"
      end)

    {:error, "Database validation failed: #{errors}"}
  end

  @spec handle_database_error({:error, any()}) :: {:error, String.t()}
  def handle_database_error({:error, reason}) do
    {:error, "Database operation failed: #{inspect(reason)}"}
  end

  @spec handle_database_error({:ok, any()}) :: {:ok, any()}
  def handle_database_error({:ok, result}) do
    {:ok, result}
  end

  @doc """
  Validates that an error response contains expected fields.

  Useful for ensuring error responses from external APIs contain the information
  we need for proper error handling.
  """
  @spec validate_error_response(map(), list(atom() | String.t())) :: :ok | {:error, String.t()}
  def validate_error_response(error_data, required_fields) when is_map(error_data) do
    missing_fields = Enum.reject(required_fields, &Map.has_key?(error_data, &1))

    case missing_fields do
      [] -> :ok
      fields -> {:error, "Error response missing fields: #{Enum.join(fields, ", ")}"}
    end
  end

  @doc """
  Wraps HTTP client errors with consistent formatting.

  Handles common HTTP client error patterns and converts them to standardized formats.
  """
  @spec handle_http_error({:error, HTTPoison.Error.t()}) :: {:error, String.t()}
  def handle_http_error({:error, %HTTPoison.Error{reason: reason}}) do
    {:error, "HTTP request failed: #{inspect(reason)}"}
  end

  @spec handle_http_error({:error, Finch.Error.t()}) :: {:error, String.t()}
  def handle_http_error({:error, %Finch.Error{reason: reason}}) do
    {:error, "HTTP request failed: #{inspect(reason)}"}
  end

  @spec handle_http_error({:ok, map()}) :: {:ok, map()} | {:error, String.t()}
  def handle_http_error({:ok, %{status: status} = response}) when status >= 400 do
    error_message = extract_error_message(response)
    {:error, "HTTP #{status}: #{error_message}"}
  end

  def handle_http_error({:ok, response}) do
    {:ok, response}
  end

  @spec handle_http_error(any()) :: any()
  def handle_http_error(other) do
    other
  end

  # Private functions

  defp log_error(level, operation, provider, reason, exception \\ nil) do
    base_message = "Integration error during #{operation} (#{provider}): #{Redactor.redact(reason)}"

    if exception do
      Logger.log(level, [base_message, "\n", Redactor.redact(exception)])
    else
      Logger.log(level, base_message)
    end
  end

  defp extract_error_message(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      {:ok, %{"error" => message}} when is_binary(message) -> message
      {:ok, %{"message" => message}} -> message
      _ -> body
    end
  end

  defp extract_error_message(%{body: body}) when is_map(body) do
    error_part = Map.get(body, "error", %{})

    case error_part do
      %{"message" => message} -> message
      message when is_binary(message) -> message
      _ -> inspect(body)
    end
  end

  defp extract_error_message(_response) do
    "Unknown error"
  end
end
