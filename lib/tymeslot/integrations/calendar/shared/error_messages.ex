defmodule Tymeslot.Integrations.Calendar.Shared.ErrorMessages do
  @moduledoc """
  What to call a calendar failure, and what to tell the account owner about it.

  Split from `ErrorHandler` because this is copy, not mechanism. Every function
  here maps a category (and sometimes a provider) onto a sentence the account
  owner reads, which means the module is almost entirely `dgettext/2` calls and
  changes whenever the wording does. Keeping it apart leaves the handler free
  to be about control flow.

  `categorize_error/1` sits here rather than with the handler because the
  categories exist to select copy: they are the vocabulary the messages and
  recovery suggestions are indexed by.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @typedoc "Coarse buckets a calendar failure falls into."
  @type error_category ::
          :auth | :network | :config | :permission | :rate_limit | :timeout | :unknown

  @typedoc "Calendar provider the failure came from."
  @type provider :: atom() | String.t()

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
  def categorize_error({:calendar_home_not_found, _url}), do: :config
  def categorize_error(:rate_limited), do: :rate_limit
  def categorize_error(:timeout), do: :timeout

  def categorize_error(reason)
      when reason in [:network_error, :server_error, :server_unresponsive],
      do: :network

  def categorize_error(_error), do: :unknown

  @doc """
  Copy for the handful of raw reasons whose category is too coarse to say
  anything the account owner can act on, or `nil` when the category message is
  good enough.

  The categories exist to index copy, and seven buckets cannot distinguish
  "your server URL is wrong" from "your server URL is fine, the calendars are
  somewhere else" — both are `:config`. Where that difference is the whole
  point of the message, it is written here against the raw reason instead.

  Takes the same raw, untranslated error as `categorize_error/1`, and for the
  same reason: this dispatches on the term, not on English text.
  """
  @spec specific_message(any(), provider()) :: String.t() | nil
  def specific_message({:calendar_home_not_found, url}, _provider) do
    dgettext(
      "dashboard_calendar_providers",
      "Connected to %{url} and your credentials were accepted, but no calendar collection was found. Enter the full URL of your calendar collection, as shown in your calendar server's settings.",
      url: url
    )
  end

  def specific_message({:error, reason}, provider), do: specific_message(reason, provider)

  def specific_message(_error, _provider), do: nil

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
