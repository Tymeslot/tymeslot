defmodule TymeslotWeb.Components.Calendar.ReminderForm do
  @moduledoc """
  The reminder lead times the calendar offers, and reading a reminder the
  side panel sends.
  """

  # Allowed reminder lead times (minutes before the event start) offered as
  # presets in the side panel. Values outside this set are rejected so the UI
  # cannot feed arbitrary integers into the provider write.
  @reminder_minutes_presets [5, 10, 30, 60, 1440]

  @doc """
  Returns the allowed reminder lead times (minutes before the event start).
  This is the single source of truth for the preset whitelist: `parse_reminder/1`
  rejects anything outside it, and the side panel builds its reminder options
  from this list rather than duplicating the values.
  """
  @spec reminder_minutes_presets() :: [pos_integer()]
  def reminder_minutes_presets, do: @reminder_minutes_presets

  @doc """
  Parses a reminder from `phx-value-method` / `phx-value-minutes` params into the
  canonical `%{method: :popup | :email, minutes_before: integer}` shape. Returns
  `:error` for an unknown method or a lead time outside the allowed presets.
  """
  @spec parse_reminder(map()) :: {:ok, %{method: atom(), minutes_before: pos_integer()}} | :error
  def parse_reminder(params) do
    with {:ok, method} <- parse_reminder_method(params["method"]),
         {:ok, minutes} <- parse_int(params["minutes"]),
         true <- minutes in @reminder_minutes_presets do
      {:ok, %{method: method, minutes_before: minutes}}
    else
      _invalid -> :error
    end
  end

  defp parse_reminder_method("popup"), do: {:ok, :popup}
  defp parse_reminder_method("email"), do: {:ok, :email}
  defp parse_reminder_method(_other), do: :error

  @doc """
  Adds `reminder` to `reminders` if it is not already present (dedup).

  Returns the updated list unchanged when `reminder` is already in it.
  """
  @spec add_reminder([map()], map()) :: [map()]
  def add_reminder(reminders, reminder) do
    if reminder in reminders, do: reminders, else: reminders ++ [reminder]
  end

  defp parse_int(text) when is_binary(text) do
    case Integer.parse(text) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  defp parse_int(_not_text), do: :error
end
