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
