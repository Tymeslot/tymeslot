defmodule Tymeslot.Integrations.Calendar.Shared.ErrorHandler do
  @moduledoc """
  Centralized error handling for calendar integrations.

  Provides consistent error formatting, categorization, and user-friendly messages
  across all calendar providers (CalDAV, Nextcloud, Google, Outlook).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  @type error_category ::
          :auth | :network | :config | :permission | :timeout | :rate_limit | :unknown
  @type provider ::
          :caldav
          | :nextcloud
          | :google
          | :outlook
          | :radicale
          | :zimbra
          | :mailbox_org
          | :apple
          | :baikal
          | :generic

  @doc """
  Sanitizes error messages to remove sensitive server information.
  Internal details are logged but not exposed to users.

  The `is_binary/1` clause pattern-matches English keywords, so `error` must
  be raw provider output: an atom, or the untranslated text an API handed
  back. What comes out is localised and must not be fed back in, nor parsed
  for meaning; see `error_field/1` for deriving a form field instead.
  """
  @spec sanitize_error_message(String.t() | atom() | tuple(), provider()) :: String.t()
  def sanitize_error_message(error, provider \\ :generic)

  def sanitize_error_message(error, provider) when is_binary(error) do
    # Log the full error internally
    Logger.error("Calendar provider error", provider: provider, error: error)

    # Return sanitized message based on common patterns
    cond do
      String.contains?(error, ["401", "unauthorized", "authentication"]) ->
        dgettext(
          "dashboard_calendar_providers",
          "Authentication failed. Please check your credentials."
        )

      String.contains?(error, ["404", "not found"]) ->
        dgettext(
          "dashboard_calendar_providers",
          "Resource not found. Please verify your configuration."
        )

      String.contains?(error, ["500", "502", "503", "504"]) ->
        dgettext(
          "dashboard_calendar_providers",
          "The calendar service is temporarily unavailable. Please try again later."
        )

      String.contains?(error, ["timeout", "timed out"]) ->
        dgettext("dashboard_calendar_providers", "The request timed out. Please try again.")

      String.contains?(error, ["SSL", "TLS", "certificate"]) ->
        dgettext(
          "dashboard_calendar_providers",
          "Secure connection failed. Please check your server configuration."
        )

      String.contains?(error, ["network", "connection refused", "ECONNREFUSED"]) ->
        dgettext(
          "dashboard_calendar_providers",
          "Unable to connect to the calendar service. Please check the URL and try again."
        )

      true ->
        # Generic message for unknown errors
        dgettext(
          "dashboard_calendar_providers",
          "An error occurred while communicating with the calendar service."
        )
    end
  end

  def sanitize_error_message(:unauthorized, :apple) do
    dgettext(
      "dashboard_calendar_providers",
      "Authentication failed. iCloud requires an app-specific password — generate one at appleid.apple.com under Sign-In and Security → App-Specific Passwords, and use it instead of your Apple ID password."
    )
  end

  def sanitize_error_message(:unauthorized, _provider) do
    dgettext(
      "dashboard_calendar_providers",
      "Authentication failed. Please check your credentials."
    )
  end

  def sanitize_error_message(:forbidden, :mailbox_org) do
    dgettext(
      "dashboard_calendar_providers",
      "Access denied. If two-factor authentication is enabled on your mailbox.org account, generate an application-specific password under Settings → Security and use that instead."
    )
  end

  def sanitize_error_message(:forbidden, :apple) do
    dgettext(
      "dashboard_calendar_providers",
      "Access denied. iCloud requires an app-specific password generated at appleid.apple.com — your Apple ID password will not work for CalDAV."
    )
  end

  def sanitize_error_message(:forbidden, _provider) do
    dgettext(
      "dashboard_calendar_providers",
      "Access denied. You do not have permission to access this calendar resource."
    )
  end

  def sanitize_error_message(:not_found, _provider) do
    dgettext(
      "dashboard_calendar_providers",
      "Resource not found. Please verify your configuration."
    )
  end

  def sanitize_error_message(:rate_limited, _provider) do
    dgettext(
      "dashboard_calendar_providers",
      "Too many requests. Please wait a moment and try again."
    )
  end

  def sanitize_error_message(:network_error, _provider) do
    dgettext(
      "dashboard_calendar_providers",
      "Network connection failed. Please check your internet connection."
    )
  end

  def sanitize_error_message(:server_error, _provider) do
    dgettext(
      "dashboard_calendar_providers",
      "The calendar service encountered an error. Please try again later."
    )
  end

  def sanitize_error_message({:error, message}, provider) when is_binary(message) do
    sanitize_error_message(message, provider)
  end

  def sanitize_error_message(error, provider) do
    Logger.error("Unknown calendar error", provider: provider, error: inspect(error))
    dgettext("dashboard_calendar_providers", "An unexpected error occurred. Please try again.")
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
  @spec format_provider_error(any(), provider(), %{atom() => term()}) :: String.t()
  def format_provider_error(error, provider, context \\ %{}) do
    {_category, message} = classify_and_format(error, provider, context)
    message
  end

  @doc """
  Classifies a provider error and formats it in one step, returning both.

  Classification runs on the *raw* error; the message it produces is
  localised. Callers that need to act on the outcome (map an auth failure to
  a form error, pick a field, decide whether to retry) must carry the
  category returned here rather than re-reading the message: once translated,
  the message is presentation and can no longer be parsed for meaning.

  ## Returns
  - `{category, user_friendly_message}`
  """
  @spec classify_and_format(any(), provider(), %{atom() => term()}) ::
          {error_category(), String.t()}
  def classify_and_format(error, provider, context \\ %{}) do
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

    # Both halves are already localised by `get_user_friendly_message/2` and
    # `get_recovery_suggestions/2`; only the punctuation joins them, so there
    # is nothing here for a translator to act on.
    message =
      if suggestions do
        "#{base_message}. #{suggestions}"
      else
        base_message
      end

    {category, message}
  end

  @doc """
  Categorizes an error based on its content.

  Only ever pass a *raw* error here: an atom, an HTTP status, an exception, or
  untranslated provider output. The `is_binary/1` clause below matches English
  keywords, so feeding it a message that has been through `dgettext` silently
  yields `:unknown` in every non-English locale. Classify first, translate
  afterwards — see `classify_and_format/3`.

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

  # The CalDAV-family `t:Tymeslot.Integrations.Calendar.CalDAV.Base.error_reason/0`
  # atoms, reached directly now that `validate_config/1` no longer runs its own
  # network probe ahead of discovery — previously these were caught earlier by
  # a provider's own `error_formatter`, which happened to embed a recognisable
  # word ("password", "not found") in the string before it ever reached here.
  def categorize_error(:unauthorized), do: :auth
  def categorize_error(:forbidden), do: :permission
  def categorize_error(:not_found), do: :config
  def categorize_error(:rate_limited), do: :rate_limit
  def categorize_error(:timeout), do: :timeout

  def categorize_error(reason)
      when reason in [:network_error, :server_error, :server_unresponsive],
      do: :network

  def categorize_error(_error), do: :unknown

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
        dgettext(
          "dashboard_calendar_providers",
          "Authentication failed for %{provider}. Please check your username and password",
          provider: provider_name
        )

      :permission ->
        dgettext(
          "dashboard_calendar_providers",
          "Access denied. You don't have permission to access this %{provider} resource",
          provider: provider_name
        )

      :timeout ->
        dgettext(
          "dashboard_calendar_providers",
          "Connection to %{provider} timed out. The server may be slow or unreachable",
          provider: provider_name
        )

      :rate_limit ->
        dgettext(
          "dashboard_calendar_providers",
          "Too many requests to %{provider}. Please wait a moment and try again",
          provider: provider_name
        )

      :network ->
        dgettext(
          "dashboard_calendar_providers",
          "Unable to connect to %{provider}. Please check your network connection and server URL",
          provider: provider_name
        )

      :config ->
        dgettext(
          "dashboard_calendar_providers",
          "%{provider} configuration error. Please verify your server URL and settings",
          provider: provider_name
        )

      :unknown ->
        dgettext("dashboard_calendar_providers", "An unexpected error occurred with %{provider}",
          provider: provider_name
        )
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
    dgettext(
      "dashboard_calendar_providers",
      "Try using an app password instead of your regular password. You can create one in Nextcloud's security settings"
    )
  end

  defp get_auth_suggestion(:auth, :radicale) do
    dgettext(
      "dashboard_calendar_providers",
      "Check your Radicale credentials. If using htpasswd authentication, ensure the password is correct"
    )
  end

  defp get_auth_suggestion(:auth, :mailbox_org) do
    dgettext(
      "dashboard_calendar_providers",
      "If two-factor authentication is enabled on your mailbox.org account, generate an application-specific password under Settings → Security and use that instead"
    )
  end

  defp get_auth_suggestion(:auth, :apple) do
    dgettext(
      "dashboard_calendar_providers",
      "iCloud requires an app-specific password. Generate one at appleid.apple.com under Sign-In and Security → App-Specific Passwords, and use it instead of your Apple ID password"
    )
  end

  defp get_auth_suggestion(:auth, _provider) do
    dgettext(
      "dashboard_calendar_providers",
      "Double-check your credentials and ensure they haven't expired"
    )
  end

  defp get_auth_suggestion(_category, _provider), do: nil

  defp get_network_suggestion(:network, :nextcloud) do
    dgettext(
      "dashboard_calendar_providers",
      "Verify the URL format: https://your-domain.com (Nextcloud path will be added automatically)"
    )
  end

  defp get_network_suggestion(:network, :radicale) do
    dgettext(
      "dashboard_calendar_providers",
      "Verify the Radicale URL including port if needed (e.g., https://radicale.example.com:5232)"
    )
  end

  defp get_network_suggestion(:network, :caldav) do
    dgettext(
      "dashboard_calendar_providers",
      "Verify the full CalDAV URL including the path (e.g., https://server.com/caldav/)"
    )
  end

  defp get_network_suggestion(_category, _provider), do: nil

  defp get_config_suggestion(:config, :radicale) do
    dgettext(
      "dashboard_calendar_providers",
      "Check that Radicale is running and accessible at the specified URL and port"
    )
  end

  defp get_config_suggestion(:config, _provider) do
    dgettext(
      "dashboard_calendar_providers",
      "Check that the server URL is correct and the CalDAV service is enabled"
    )
  end

  defp get_config_suggestion(_category, _provider), do: nil

  defp get_other_suggestion(:timeout) do
    dgettext(
      "dashboard_calendar_providers",
      "If the problem persists, contact your calendar server administrator"
    )
  end

  defp get_other_suggestion(:rate_limit) do
    dgettext("dashboard_calendar_providers", "Wait 60 seconds before trying again")
  end

  defp get_other_suggestion(_category), do: nil

  @doc """
  Creates a validation error in the format expected by the UI.

  `message` is already localised presentation text, so it is never inspected
  to work out which field is at fault. Callers derive `field` from the raw
  error instead, typically via `error_field/1`.

  ## Parameters
  - `message` - The error message, ready to display
  - `field` - The form field to attach it to (defaults to `:base`)

  ## Returns
  - Pseudo-changeset error structure
  """
  @spec create_validation_error(String.t(), atom()) :: Ecto.Changeset.t()
  def create_validation_error(message, field \\ :base) do
    %Ecto.Changeset{
      errors: [{field, {message, []}}],
      valid?: false
    }
  end

  @doc """
  Picks the CalDAV form field an error should be attached to, from the raw
  error rather than from any message built out of it.

  Categorisation does the work, so this stays correct in every locale.

  ## Parameters
  - `error` - The raw error (atom, status code, untranslated provider output)

  ## Returns
  - A field name for `create_validation_error/2`
  """
  @spec error_field(any()) :: atom()
  def error_field(error) do
    case categorize_error(error) do
      # Both an auth rejection and a permission refusal are almost always
      # answered by a different secret: an app-specific password rather than
      # the account one.
      :auth -> :password
      :permission -> :password
      :config -> :base_url
      :network -> :base_url
      :timeout -> :base_url
      _other_category -> :base
    end
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
  @spec with_error_handling(provider(), function(), %{atom() => term()}) ::
          {:ok, any()} | {:error, String.t()}
  def with_error_handling(provider, operation, context \\ %{}) do
    case with_classified_error_handling(provider, operation, context) do
      {:error, {_category, message}} -> {:error, message}
      ok -> ok
    end
  end

  @doc """
  As `with_error_handling/3`, but keeps the category alongside the message.

  Use this wherever a caller further up has to act on *what kind* of failure
  it was. The category is derived from the raw error before the message is
  built, so it survives translation; the message never has to be parsed back.

  ## Returns
  - `{:ok, result}` or `{:error, {category, formatted_message}}`
  """
  @spec with_classified_error_handling(provider(), function(), %{atom() => term()}) ::
          {:ok, any()} | {:error, {error_category(), String.t()}}
  def with_classified_error_handling(provider, operation, context \\ %{}) do
    case operation.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, classify_and_format(reason, provider, context)}

      error ->
        {:error, classify_and_format(error, provider, context)}
    end
  rescue
    exception ->
      {:error, classify_and_format(exception, provider, context)}
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
        _other_category -> 1_000
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
      :caldav -> dgettext("dashboard_calendar_providers", "CalDAV server")
      :nextcloud -> "Nextcloud"
      :radicale -> "Radicale"
      :zimbra -> "Zimbra"
      :mailbox_org -> "mailbox.org"
      :apple -> "Apple iCloud"
      :google -> "Google Calendar"
      :outlook -> "Outlook Calendar"
      _other_provider -> dgettext("dashboard_calendar_providers", "calendar provider")
    end
  end
end
