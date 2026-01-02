defmodule TymeslotWeb.Components.Shared.TimeOptions do
  @moduledoc """
  Shared helpers for time-related UI options used across dashboard components.
  """

  use Phoenix.Component

  @doc """
  Returns 15-minute interval options as {label, value} pairs in 24h HH:MM.
  """
  @spec time_options() :: list({String.t(), String.t()})
  def time_options do
    for hour <- 0..23, minute <- [0, 15, 30, 45] do
      time_str =
        String.pad_leading("#{hour}", 2, "0") <> ":" <> String.pad_leading("#{minute}", 2, "0")

      {time_str, time_str}
    end
  end
end
