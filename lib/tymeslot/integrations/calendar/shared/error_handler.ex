defmodule Tymeslot.Integrations.Calendar.Shared.ErrorHandler do
  @moduledoc """
  Error handling for calendar integrations: redacting raw provider output, and
  wrapping an operation so any failure comes back classified.

  The wording lives next door in `ErrorMessages`, which owns the categories and
  the sentences indexed by them. This module is the mechanism: what gets
  logged, what gets hidden, and what shape a caller receives.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Integrations.Calendar.Shared.ErrorMessages

  @type error_category :: ErrorMessages.error_category()
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
          | :exchange
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

  # EWS states its own failures as response codes rather than as an HTTP
  # status, so they arrive as a tuple. `ErrorAccessDenied` is the one an
  # account owner hits and can act on: the credentials were accepted, but the
  # account cannot read the mailbox — which is what `:forbidden` already says.
  def sanitize_error_message({:response_code, "ErrorAccessDenied"}, provider) do
    sanitize_error_message(:forbidden, provider)
  end

  # Every other code is a server-side name with no advice attached to it, so it
  # keeps the generic sentence rather than being given an invented one. It is
  # still logged under the code the server sent, which is what distinguishes it
  # from the unknown-error catch-all below and is the only record of what the
  # server actually said.
  def sanitize_error_message({:response_code, code}, provider) when is_binary(code) do
    Logger.error("Calendar provider error", provider: provider, error: code)

    dgettext(
      "dashboard_calendar_providers",
      "An error occurred while communicating with the calendar service."
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
    category = ErrorMessages.categorize_error(error)

    # A reason-specific message is already written about this exact failure and
    # carries its own advice, so it replaces the category's message *and* its
    # recovery suggestion rather than being appended to either.
    {base_message, suggestions} =
      case ErrorMessages.specific_message(error, provider) do
        nil ->
          {ErrorMessages.get_user_friendly_message(category, provider),
           ErrorMessages.get_recovery_suggestions(category, provider)}

        specific_message ->
          {specific_message, nil}
      end

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
end
