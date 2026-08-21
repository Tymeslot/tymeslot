defmodule Tymeslot.Integrations.Calendar.DisplayHelpers do
  @moduledoc """
  User-facing string helpers for calendar integrations — error message
  normalisation, provider display names, and calendar name extraction.

  Application code should call the public `Tymeslot.Integrations.Calendar`
  facade rather than this module directly.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Providers.Directory

  @doc """
  Map connection/validation error atoms to user-friendly messages.
  """
  @spec connection_error_message(term()) :: String.t()
  def connection_error_message(:timeout),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Calendar service is not responding. Please try again later."
      )

  def connection_error_message(:authentication_failed),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Authentication failed. Please reconnect your calendar."
      )

  def connection_error_message(:token_expired),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Your calendar access has expired. Please reconnect."
      )

  def connection_error_message(:network_error),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Unable to reach calendar service. Check your internet connection."
      )

  def connection_error_message(:invalid_credentials),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Invalid calendar credentials. Please update your connection."
      )

  def connection_error_message(_other),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Failed to connect to calendar. Please try again or reconnect."
      )

  @doc """
  Format provider display name for UI consumption.
  """
  @spec format_provider_display_name(String.t()) :: String.t()
  def format_provider_display_name(provider) do
    Directory.format_provider_name(:calendar, provider)
  end

  @doc """
  Names an integration in a way that survives a second account of the same
  provider.

  The `name` column cannot do this alone. Both OAuth helpers store a constant —
  `"Google Calendar"` at `google_oauth_helper.ex`, `"Outlook Calendar"` at
  `outlook_oauth_helper.ex` — and the onboarding wizard stores
  `"CalDAV Calendar"` without ever showing a name field, so an organiser with
  two Google accounts gets two rows that read identically everywhere a name is
  rendered. The account they differ in was already stored at connect time; only
  the display ignored it.

  Composing here rather than writing a better `name` at connect time is
  deliberate. Nothing records whether a name was chosen or generated — a rename
  writes `name` and sets no flag — so a backfill would have to guess, and
  guessing wrong overwrites something a person typed. Composing costs nothing at
  rest, fixes rows already connected, and keeps `name` meaning "what the
  organiser calls this" rather than a derived string that goes stale when an
  account's email changes.

  The qualifier differs by provider family because the families store different
  things:

  - OAuth (Google, Outlook) has `provider_account_email`, which is the account.
  - The CalDAV family has `provider_account_id` as `base_url||username`. Only
    the username is shown: the host is already implied by the provider's own
    name, and the pair is long enough to crowd out the name in a dropdown.
  - An ICS subscription's `provider_account_id` is a SHA-256 digest of the feed
    URL — unique but unreadable — so its origin serves instead. Two feeds from
    one host stay indistinguishable, which is why that form asks for a name.

  A qualifier already present in the name is not repeated, so an organiser who
  renamed a calendar to its own account address does not read it twice.
  """
  @spec integration_label(map()) :: String.t()
  def integration_label(integration) do
    name = integration_name(integration)

    case integration_qualifier(integration) do
      nil -> name
      qualifier -> "#{name} — #{qualifier}"
    end
  end

  @doc """
  The calendar's own name, without the account qualifier.

  Exposed as a half of `integration_label/1` rather than duplicated, because
  the link grid stacks the two on separate lines: a row header wide enough for
  "Google Calendar — organiser@example.com" forces the grid past the viewport
  before the third calendar, and truncating it hides the account, which is the
  only half that tells two Google rows apart.
  """
  @spec integration_name(map()) :: String.t()
  def integration_name(%{name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> fallback_name()
      trimmed -> trimmed
    end
  end

  def integration_name(_integration), do: fallback_name()

  @doc """
  The account the calendar belongs to, or `nil` where none can be shown.

  `nil` covers two different cases that the caller renders identically — no
  column carries an account (an OAuth row with no email recorded), and the name
  already carries it, which `integration_label/1` has always suppressed. A
  split that reported the qualifier anyway would print a second line the
  composed label deliberately omits.

  An em dash joins them in `integration_label/1` rather than parentheses: the
  qualifier is a second fact about the calendar, not an aside about the first,
  and it reads the same in every locale this ships in.
  """
  @spec integration_qualifier(map()) :: String.t() | nil
  def integration_qualifier(integration) do
    case qualifier(integration) do
      nil ->
        nil

      qualifier ->
        if repeats?(integration_name(integration), qualifier), do: nil, else: qualifier
    end
  end

  defp fallback_name, do: dgettext("dashboard_common", "Calendar")

  # Whole words, not a substring: a username of "al" inside "Personal" is a
  # coincidence, and treating it as a repetition would drop the qualifier from
  # precisely the calendars that need telling apart.
  defp repeats?(name, qualifier) do
    qualifier = String.downcase(qualifier)

    name
    |> String.downcase()
    |> String.split(~r/[^\w.@+-]+/u, trim: true)
    |> Enum.member?(qualifier)
  end

  defp qualifier(%{provider_account_email: email}) when is_binary(email) and email != "",
    do: email

  defp qualifier(integration) do
    if subscription?(Map.get(integration, :provider)) do
      host_only(Map.get(integration, :base_url))
    else
      caldav_username(Map.get(integration, :provider_account_id))
    end
  end

  defp subscription?(provider), do: provider in ["ics_url", :ics_url]

  # `base_url` already holds only the feed's origin for a subscription; the
  # scheme is noise in a picker, so only the host survives.
  defp host_only(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _no_host -> nil
    end
  end

  defp host_only(_url), do: nil

  # `nil` for anything without the `||` separator: an OAuth `provider_account_id`
  # is an opaque subject identifier and an ICS one is a digest, and showing
  # either would be worse than showing nothing.
  defp caldav_username(account_id) when is_binary(account_id) do
    case String.split(account_id, "||", parts: 2) do
      [_base_url, username] when username != "" -> username
      _no_separator -> nil
    end
  end

  defp caldav_username(_account_id), do: nil

  @doc """
  Helper to extract a friendly display name from a calendar.
  Handles the case where Radicale calendars may have UUIDs as names.
  """
  @spec extract_calendar_display_name(CalendarEntry.t() | map()) :: String.t()
  def extract_calendar_display_name(calendar) do
    entry = CalendarEntry.normalize(calendar)
    raw_name = entry.name
    path = entry.path
    id = entry.id

    cond do
      # If name exists and doesn't look like a UUID, use it
      raw_name && !uuid_like?(raw_name) ->
        raw_name

      # If path exists, try to extract a friendly name from it
      path ->
        extract_name_from_path(path)

      # If id doesn't look like a UUID, use it
      id && !uuid_like?(id) ->
        id

      # Last resort: use the raw name even if it's a UUID
      raw_name ->
        raw_name

      true ->
        dgettext("dashboard_common", "Calendar")
    end
  end

  @doc """
  Normalizes discovery errors into user-friendly strings.
  """
  @spec normalize_discovery_error(any()) :: String.t()
  # Discovery's classified error shape: the category is for callers that have
  # a decision to make, and displaying an error is not one of them.
  def normalize_discovery_error({category, message})
      when is_atom(category) and is_binary(message),
      do: message

  def normalize_discovery_error(reason) do
    errors =
      reason
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    case errors do
      [] ->
        dgettext(
          "dashboard_calendar_providers",
          "Calendar discovery failed. Please check your credentials and try again."
        )

      errors ->
        Enum.map_join(errors, ", ", &to_string/1)
    end
  end

  # Check if a string looks like a UUID
  defp uuid_like?(str) when is_binary(str) do
    String.match?(str, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  defp uuid_like?(_non_string), do: false

  # Extract a friendly name from a path like "/user/calendar-name/" -> "Calendar Name"
  defp extract_name_from_path(path) when is_binary(path) do
    segments =
      path
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    case List.last(segments) do
      nil ->
        dgettext("dashboard_common", "Calendar")

      name ->
        name
        |> String.replace(~r/\.(ics|cal)$/, "")
        |> String.replace(["_", "-"], " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp extract_name_from_path(_arg), do: dgettext("dashboard_common", "Calendar")
end
