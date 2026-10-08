defmodule TymeslotWeb.Themes.Shared.TimezoneHelpers do
  @moduledoc """
  Timezone helpers for the booking pages: which timezone the booker sees times
  in, and how a timezone is displayed.

  Provides formatting functions used across theme timezone selectors
  and dashboard timezone dropdowns. Keeps the display logic in one place
  while each theme retains its own template and CSS.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_params: 1]

  alias Tymeslot.Profiles
  alias Tymeslot.Timezones

  @doc """
  Assigns `:user_timezone`, the timezone every time on the page is shown in.

  A zone a language switch carried (`visitor_timezone`, the one the visitor was
  seeing times in) wins. Otherwise the zone the booker's browser reported when
  the socket connected wins, since it is where the booker actually is; a
  `timezone` URL parameter covers the
  static render, before the browser has reported anything; the default covers
  the rest. The result is always a valid, current IANA id: renamed zones are
  normalised, and an unknown one falls back to the default (or `"UTC"` should
  even that be invalid).

  Reads the connect params, so it can only be called during `mount/3`.
  """
  @spec assign_user_timezone(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_user_timezone(socket, params) do
    requested =
      carried_timezone(params) || get_connect_params(socket)["timezone"] || params["timezone"] ||
        Profiles.get_default_timezone()

    normalized = Timezones.normalize(requested)

    timezone = if Timezones.valid?(normalized), do: normalized, else: fallback_timezone()

    assign(socket, :user_timezone, timezone)
  end

  # The timezone the visitor was seeing times in before a language switch
  # (`PathHandlers` carries it with the chosen day and time, which are wall
  # clock in that zone). It wins over the browser's, as the visitor's own
  # choice did before the redirect; one that is not a valid zone is ignored.
  defp carried_timezone(%{"visitor_timezone" => timezone}) when is_binary(timezone) do
    normalized = Timezones.normalize(timezone)
    if Timezones.valid?(normalized), do: normalized
  end

  defp carried_timezone(_params), do: nil

  defp fallback_timezone do
    default = Profiles.get_default_timezone()
    if Timezones.valid?(default), do: default, else: "UTC"
  end

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
