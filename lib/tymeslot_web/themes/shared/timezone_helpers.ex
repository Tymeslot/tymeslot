defmodule TymeslotWeb.Themes.Shared.TimezoneHelpers do
  @moduledoc """
  Shared timezone display helpers for scheduling theme components.

  Provides formatting functions used across theme timezone selectors
  and dashboard timezone dropdowns. Keeps the display logic in one place
  while each theme retains its own template and CSS.
  """

  @doc """
  Formats the current local time for a timezone as "HH:MM".
  Returns "--:--" if the timezone is invalid.

  ## Examples

      iex> TimezoneHelpers.format_local_time("Europe/Berlin")
      "14:30"

      iex> TimezoneHelpers.format_local_time("Invalid/Zone")
      "--:--"
  """
  @spec format_local_time(String.t()) :: String.t()
  def format_local_time(timezone) do
    case DateTime.now(timezone) do
      {:ok, datetime} ->
        datetime |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 5)

      _other ->
        "--:--"
    end
  end
end
