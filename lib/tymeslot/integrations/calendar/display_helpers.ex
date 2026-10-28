defmodule Tymeslot.Integrations.Calendar.DisplayHelpers do
  @moduledoc """
  User-facing string helpers for calendar integrations — error message
  normalisation, provider display names, and calendar name extraction.

  Application code should call the public `Tymeslot.Integrations.Calendar`
  facade rather than this module directly.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Shared.Providers.Directory

  @doc """
  Map connection/validation error atoms to user-friendly messages.
  """
  @spec connection_error_message(term()) :: String.t()
  def connection_error_message(:timeout),
    do:
      dgettext(
        "integrations_calendar",
        "Calendar service is not responding. Please try again later."
      )

  def connection_error_message(:authentication_failed),
    do:
      dgettext(
        "integrations_calendar",
        "Authentication failed. Please reconnect your calendar."
      )

  def connection_error_message(:token_expired),
    do:
      dgettext(
        "integrations_calendar",
        "Your calendar access has expired. Please reconnect."
      )

  def connection_error_message(:network_error),
    do:
      dgettext(
        "integrations_calendar",
        "Unable to reach calendar service. Check your internet connection."
      )

  def connection_error_message(:invalid_credentials),
    do:
      dgettext(
        "integrations_calendar",
        "Invalid calendar credentials. Please update your connection."
      )

  def connection_error_message(_other),
    do:
      dgettext(
        "integrations_calendar",
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
    %CalendarEntry{name: raw_name, path: path, id: id} = CalendarEntry.normalize(calendar)

    # In order of preference: a name that doesn't look like a UUID, a friendly
    # name derived from the path, an id that doesn't look like a UUID, and as a
    # last resort the raw name even if it is a UUID.
    with :error <- readable(raw_name),
         :error <- name_from_path(path),
         :error <- readable(id),
         :error <- present(raw_name) do
      dgettext("dashboard_common", "Calendar")
    else
      {:ok, name} -> name
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
          "integrations_calendar",
          "Calendar discovery failed. Please check your credentials and try again."
        )

      errors ->
        Enum.map_join(errors, ", ", &to_string/1)
    end
  end

  defp readable(value) when is_binary(value) do
    if uuid_like?(value), do: :error, else: {:ok, value}
  end

  defp readable(_value), do: :error

  defp name_from_path(path) when is_binary(path), do: {:ok, extract_name_from_path(path)}
  defp name_from_path(_path), do: :error

  defp present(value) when is_binary(value), do: {:ok, value}
  defp present(_value), do: :error

  # Check if a string looks like a UUID
  defp uuid_like?(str) when is_binary(str) do
    String.match?(str, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

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
end
