defmodule Tymeslot.Integrations.Calendar.Shared.ErrorHandler do
  @moduledoc """
  Centralized error handling for calendar integrations.

  Provides consistent error formatting, categorization, and user-friendly messages
  across all calendar providers (CalDAV, Nextcloud, Google, Outlook).
  """

  require Logger

  @type error_category ::
          :auth | :network | :config | :permission | :timeout | :rate_limit | :unknown
  @type provider :: :caldav | :nextcloud | :google | :outlook | :radicale | :generic

  @doc """
  Sanitizes error messages to remove sensitive server information.
  Internal details are logged but not exposed to users.
  """
  @spec sanitize_error_message(String.t() | atom() | tuple(), provider()) :: String.t()
  def sanitize_error_message(error, provider \\ :generic)

  def sanitize_error_message(error, provider) when is_binary(error) do
    # Log the full error internally
    Logger.error("Calendar provider error", provider: provider, error: error)

    # Return sanitized message based on common patterns
    cond do
      String.contains?(error, ["401", "unauthorized", "authentication"]) ->
        "Authentication failed. Please check your credentials."

      String.contains?(error, ["404", "not found"]) ->
        "Resource not found. Please verify your configuration."

      String.contains?(error, ["500", "502", "503", "504"]) ->
        "The calendar service is temporarily unavailable. Please try again later."

      String.contains?(error, ["timeout", "timed out"]) ->
        "The request timed out. Please try again."

      String.contains?(error, ["SSL", "TLS", "certificate"]) ->
        "Secure connection failed. Please check your server configuration."

      String.contains?(error, ["network", "connection refused", "ECONNREFUSED"]) ->
        "Unable to connect to the calendar service. Please check the URL and try again."

      true ->
        # Generic message for unknown errors
        "An error occurred while communicating with the calendar service."
    end
  end

  def sanitize_error_message(:unauthorized, _provider) do
    "Authentication failed. Please check your credentials."
  end

  def sanitize_error_message(:not_found, _provider) do
    "Resource not found. Please verify your configuration."
  end

  def sanitize_error_message(:rate_limited, _provider) do
    "Too many requests. Please wait a moment and try again."
  end

  def sanitize_error_message(:network_error, _provider) do
    "Network connection failed. Please check your internet connection."
  end

  def sanitize_error_message(:server_error, _provider) do
    "The calendar service encountered an error. Please try again later."
  end

  def sanitize_error_message({:error, message}, provider) when is_binary(message) do
    sanitize_error_message(message, provider)
  end

  def sanitize_error_message(error, provider) do
    Logger.error("Unknown calendar error", provider: provider, error: inspect(error))
    "An unexpected error occurred. Please try again."
  end

  @doc """
  Formats a provider error into a user-friendly message.

  ## Parameters
  - `error` - The error to format (can be string, tuple, or exception)
  - `provider` - The provider that generated the error
  - `context` - Additional context (e.g., operation being performed)

  ## Returns
  - User-friendly error message string
  """
  @spec format_provider_error(any(), provider(), map()) :: String.t()
  def format_provider_error(error, provider, context \\ %{}) do
    category = categorize_error(error)
    base_message = get_user_friendly_message(category, provider)
    suggestions = get_recovery_suggestions(category, provider)

    # Log the original error for debugging
    Logger.debug("Calendar provider error",
      provider: provider,
      category: category,
      error: inspect(error),
      context: context
    )

    if suggestions do
      "#{base_message}. #{suggestions}"
    else
      base_message
    end
  end

  @doc """
  Categorizes an error based on its content.

  ## Parameters
  - `error` - The error to categorize

  ## Returns
  - Error category atom
  """
  @spec categorize_error(any()) :: error_category()
  def categorize_error(error) when is_binary(error) do
    error_lower = String.downcase(error)

    cond do
      contains_any?(error_lower, [
        "unauthorized",
        "401",
        "authentication",
        "password",
        "credentials"
      ]) ->
        :auth

      contains_any?(error_lower, ["403", "forbidden", "permission", "access denied"]) ->
        :permission

      contains_any?(error_lower, ["timeout", "timed out", "deadline"]) ->
        :timeout

      contains_any?(error_lower, ["rate limit", "429", "too many requests"]) ->
        :rate_limit

      contains_any?(error_lower, ["connection", "network", "unreachable", "dns", "resolve"]) ->
        :network

      contains_any?(error_lower, ["url", "endpoint", "server", "host", "configuration"]) ->
        :config

      true ->
        :unknown
    end
  end

  def categorize_error({:error, reason}), do: categorize_error(reason)
  def categorize_error(%{message: message}), do: categorize_error(message)
  def categorize_error(%{reason: reason}), do: categorize_error(reason)

  # HTTP status codes
  def categorize_error(401), do: :auth
  def categorize_error(403), do: :permission
  def categorize_error(404), do: :config
  def categorize_error(429), do: :rate_limit
  def categorize_error(status) when is_integer(status) and status >= 500, do: :network

  def categorize_error(_), do: :unknown

  @doc """
  Gets a user-friendly error message for a category and provider.

  ## Parameters
  - `category` - The error category
  - `provider` - The provider

  ## Returns
  - User-friendly error message
  """
  @spec get_user_friendly_message(error_category(), provider()) :: String.t()
  def get_user_friendly_message(category, provider) do
    provider_name = format_provider_name(provider)

    case category do
      :auth ->
        "Authentication failed for #{provider_name}. Please check your username and password"

      :permission ->
        "Access denied. You don't have permission to access this #{provider_name} resource"

      :timeout ->
        "Connection to #{provider_name} timed out. The server may be slow or unreachable"

      :rate_limit ->
        "Too many requests to #{provider_name}. Please wait a moment and try again"

      :network ->
        "Unable to connect to #{provider_name}. Please check your network connection and server URL"

      :config ->
        "#{provider_name} configuration error. Please verify your server URL and settings"

      :unknown ->
        "An unexpected error occurred with #{provider_name}"
    end
  end

  @doc """
  Gets recovery suggestions for an error category.

  ## Parameters
  - `category` - The error category
  - `provider` - The provider (optional, for provider-specific suggestions)

  ## Returns
  - Recovery suggestion string or nil
  """
  @spec get_recovery_suggestions(error_category(), provider()) :: String.t() | nil
  def get_recovery_suggestions(category, provider \\ :caldav) do
    get_auth_suggestion(category, provider) ||
      get_network_suggestion(category, provider) ||
      get_config_suggestion(category, provider) ||
      get_other_suggestion(category)
  end

  defp get_auth_suggestion(:auth, :nextcloud) do
    "Try using an app password instead of your regular password. You can create one in Nextcloud's security settings"
  end

  defp get_auth_suggestion(:auth, :radicale) do
    "Check your Radicale credentials. If using htpasswd authentication, ensure the password is correct"
  end

  defp get_auth_suggestion(:auth, _) do
    "Double-check your credentials and ensure they haven't expired"
  end

  defp get_auth_suggestion(_, _), do: nil

  defp get_network_suggestion(:network, :nextcloud) do
    "Verify the URL format: https://your-domain.com (Nextcloud path will be added automatically)"
  end

  defp get_network_suggestion(:network, :radicale) do
    "Verify the Radicale URL including port if needed (e.g., https://radicale.example.com:5232)"
  end

  defp get_network_suggestion(:network, :caldav) do
    "Verify the full CalDAV URL including the path (e.g., https://server.com/caldav/)"
  end

  defp get_network_suggestion(_, _), do: nil

  defp get_config_suggestion(:config, :radicale) do
    "Check that Radicale is running and accessible at the specified URL and port"
  end

  defp get_config_suggestion(:config, _) do
    "Check that the server URL is correct and the CalDAV service is enabled"
  end

  defp get_config_suggestion(_, _), do: nil

  defp get_other_suggestion(:timeout) do
    "If the problem persists, contact your calendar server administrator"
  end

  defp get_other_suggestion(:rate_limit) do
    "Wait 60 seconds before trying again"
  end

  defp get_other_suggestion(_), do: nil

  @doc """
  Creates a validation error in the format expected by the UI.

  ## Parameters
  - `message` - The error message
  - `field` - The field that caused the error (optional)

  ## Returns
  - Pseudo-changeset error structure
  """
  @spec create_validation_error(String.t(), atom() | nil) :: map()
  def create_validation_error(message, field \\ nil) do
    error_field = field || detect_error_field(message)

    %Ecto.Changeset{
      errors: [{error_field, {message, []}}],
      valid?: false
    }
  end

  @doc """
  Wraps an operation with error handling and formatting.

  ## Parameters
  - `provider` - The provider performing the operation
  - `operation` - Function to execute
  - `context` - Context for error messages

  ## Returns
  - `{:ok, result}` or `{:error, formatted_message}`
  """
  @spec with_error_handling(provider(), function(), map()) :: {:ok, any()} | {:error, String.t()}
  def with_error_handling(provider, operation, context \\ %{}) do
    case operation.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, format_provider_error(reason, provider, context)}

      error ->
        {:error, format_provider_error(error, provider, context)}
    end
  rescue
    exception ->
      {:error, format_provider_error(exception, provider, context)}
  end

  @doc """
  Checks if an error is retryable.

  ## Parameters
  - `error` - The error to check

  ## Returns
  - `true` if the error is retryable, `false` otherwise
  """
  @spec retryable?(any()) :: boolean()
  def retryable?(error) do
    category = categorize_error(error)
    category in [:timeout, :network, :rate_limit]
  end

  @doc """
  Gets the retry delay for an error in milliseconds.

  ## Parameters
  - `error` - The error
  - `attempt` - The current attempt number

  ## Returns
  - Delay in milliseconds
  """
  @spec get_retry_delay(any(), integer()) :: integer()
  def get_retry_delay(error, attempt \\ 1) do
    category = categorize_error(error)

    base_delay =
      case category do
        # 1 minute for rate limits
        :rate_limit -> 60_000
        # 5 seconds for timeouts
        :timeout -> 5_000
        # 3 seconds for network errors
        :network -> 3_000
        # 1 second default
        _ -> 1_000
      end

    # Exponential backoff with jitter
    delay = base_delay * attempt
    jitter = :rand.uniform(1000)
    # Cap at 5 minutes
    min(delay + jitter, 300_000)
  end

  # Private helper functions

  defp contains_any?(string, patterns) do
    Enum.any?(patterns, &String.contains?(string, &1))
  end

  defp format_provider_name(provider) do
    case provider do
      :caldav -> "CalDAV server"
      :nextcloud -> "Nextcloud"
      :radicale -> "Radicale"
      :google -> "Google Calendar"
      :outlook -> "Outlook Calendar"
      _ -> "calendar provider"
    end
  end

  defp detect_error_field(message) do
    message_lower = String.downcase(message)

    cond do
      String.contains?(message_lower, ["password", "authentication", "unauthorized"]) ->
        :password

      String.contains?(message_lower, ["username", "user"]) ->
        :username

      String.contains?(message_lower, ["url", "domain", "endpoint", "server"]) ->
        :base_url

      String.contains?(message_lower, ["calendar", "path"]) ->
        :calendar_paths

      true ->
        :base
    end
  end
end
