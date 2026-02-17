defmodule TymeslotWeb.Dashboard.Automation.Helpers do
  @moduledoc """
  Helper functions for the AutomationSettingsComponent.
  Contains business logic, state management, and utility functions.
  """

  alias Tymeslot.Security.WebhookInputProcessor
  alias Tymeslot.Utils.FormHelpers
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers

  @doc """
  Toggles an event in the list of selected events.
  """
  @spec toggle_event(map(), String.t()) :: map()
  def toggle_event(form_values, event) do
    current_events = Map.get(form_values, "events", [])

    new_events =
      if event in current_events do
        List.delete(current_events, event)
      else
        [event | current_events]
      end

    Map.put(form_values, "events", new_events)
  end

  @doc """
  Validates a single field and returns updated errors map.
  """
  @spec validate_field(map(), map(), String.t(), any(), map()) :: map()
  def validate_field(form_values, current_errors, field, value, metadata) do
    allowed_fields = ["name", "url", "events"]

    if field in allowed_fields do
      updated_values = Map.put(form_values, field, value)

      case WebhookInputProcessor.validate_webhook_form(updated_values, metadata: metadata) do
        {:ok, _sanitized} ->
          field_atom = String.to_existing_atom(field)
          Map.delete(current_errors, field_atom)

        {:error, errors} ->
          field_atom = String.to_existing_atom(field)
          field_error = Map.get(errors, field_atom)

          if field_error do
            Map.put(current_errors, field_atom, field_error)
          else
            Map.delete(current_errors, field_atom)
          end
      end
    else
      current_errors
    end
  end

  @doc """
  Parses an ID from string or integer.
  """
  @spec parse_id(integer() | String.t()) :: integer()
  def parse_id(id) when is_integer(id), do: id

  def parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _value} -> int
      _other -> 0
    end
  end

  @doc """
  Formats changeset errors into a flat map.
  """
  @spec format_changeset_errors(Ecto.Changeset.t()) :: map()
  def format_changeset_errors(changeset) do
    FormHelpers.format_changeset_errors(changeset)
    |> Enum.map(fn {k, v} -> {k, List.first(v)} end)
    |> Map.new()
  end

  @doc """
  Gets security metadata from socket.
  """
  @spec get_security_metadata(Phoenix.LiveView.Socket.t()) :: map()
  def get_security_metadata(socket) do
    DashboardHelpers.get_security_metadata(socket)
  end
end
