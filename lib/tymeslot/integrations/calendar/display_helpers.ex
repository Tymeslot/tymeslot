defmodule Tymeslot.Integrations.Calendar.DisplayHelpers do
  @moduledoc """
  User-facing string helpers for calendar integrations — error message
  normalisation, provider display names, and calendar name extraction.

  Application code should call the public `Tymeslot.Integrations.Calendar`
  facade rather than this module directly.
  """

  alias Tymeslot.Integrations.Providers.Directory

  @doc """
  Map connection/validation error atoms to user-friendly messages.
  """
  @spec connection_error_message(term()) :: String.t()
  def connection_error_message(reason) do
    case reason do
      :timeout -> "Calendar service is not responding. Please try again later."
      :authentication_failed -> "Authentication failed. Please reconnect your calendar."
      :token_expired -> "Your calendar access has expired. Please reconnect."
      :network_error -> "Unable to reach calendar service. Check your internet connection."
      :invalid_credentials -> "Invalid calendar credentials. Please update your connection."
      _other -> "Failed to connect to calendar. Please try again or reconnect."
    end
  end

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
  @spec extract_calendar_display_name(%{
          optional(String.t()) => term(),
          optional(atom()) => term()
        }) ::
          String.t()
  def extract_calendar_display_name(calendar) do
    raw_name = calendar["name"] || calendar[:name]
    path = calendar["path"] || calendar[:path] || calendar["href"] || calendar[:href]
    id = calendar["id"] || calendar[:id]

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
        "Calendar"
    end
  end

  @doc """
  Normalizes discovery errors into user-friendly strings.
  """
  @spec normalize_discovery_error(any()) :: String.t()
  def normalize_discovery_error(reason) do
    errors =
      reason
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    case errors do
      [] -> "Calendar discovery failed. Please check your credentials and try again."
      errors -> Enum.map_join(errors, ", ", &to_string/1)
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
        "Calendar"

      name ->
        name
        |> String.replace(~r/\.(ics|cal)$/, "")
        |> String.replace(["_", "-"], " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp extract_name_from_path(_arg), do: "Calendar"
end
