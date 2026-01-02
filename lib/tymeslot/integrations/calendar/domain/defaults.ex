defmodule Tymeslot.Integrations.Calendar.Defaults do
  @moduledoc """
  Shared helpers for determining default booking calendars within an integration.

  Centralizes logic for deriving a reasonable default calendar ID from
  provider-specific calendar lists and fields. Keep this module dependency-free
  from other contexts to allow easy reuse.
  """

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema

  @doc """
  Determine best default calendar within an integration struct.

  Priority:
  - If calendar_list present: primary -> selected -> first
  - Else provider fallback: google => "primary", outlook => "default"
  - Else first calendar_paths entry
  """
  @spec resolve_default_calendar_id(CalendarIntegrationSchema.t()) :: String.t() | nil
  def resolve_default_calendar_id(%CalendarIntegrationSchema{} = integration) do
    calendars = integration.calendar_list || []

    case pick_from_list(calendars) do
      nil -> provider_default(integration) || first_path(integration)
      id -> id
    end
  end

  defp pick_from_list(calendars) do
    if is_list(calendars) and calendars != [] do
      primary_id(calendars) || selected_id(calendars) || first_id_from_list(calendars)
    else
      nil
    end
  end

  defp provider_default(%{provider: "google"}), do: "primary"
  defp provider_default(%{provider: "outlook"}), do: "default"
  defp provider_default(_), do: nil

  defp first_path(%{calendar_paths: paths}) when is_list(paths) and paths != [],
    do: List.first(paths)

  defp first_path(_), do: nil

  @doc """
  Find provider-primary calendar ID from a calendar list.
  """
  @spec primary_id(list()) :: String.t() | nil
  def primary_id(calendars) when is_list(calendars) do
    case Enum.find(calendars, fn cal -> cal["primary"] == true || cal[:primary] == true end) do
      nil -> nil
      cal -> cal["id"] || cal[:id] || cal["path"] || cal[:path]
    end
  end

  def primary_id(_), do: nil

  @doc """
  Find first selected calendar ID from a calendar list.
  """
  @spec selected_id(list()) :: String.t() | nil
  def selected_id(calendars) when is_list(calendars) do
    case Enum.find(calendars, fn cal -> cal["selected"] == true || cal[:selected] == true end) do
      nil -> nil
      cal -> cal["id"] || cal[:id] || cal["path"] || cal[:path]
    end
  end

  def selected_id(_), do: nil

  @doc """
  Get the first calendar ID from a calendar list.
  """
  @spec first_id_from_list(list()) :: String.t() | nil
  def first_id_from_list(calendars) when is_list(calendars) do
    case List.first(calendars) do
      nil -> nil
      cal -> cal["id"] || cal[:id] || cal["path"] || cal[:path]
    end
  end

  def first_id_from_list(_), do: nil
end
