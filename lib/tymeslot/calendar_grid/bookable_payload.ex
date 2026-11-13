defmodule Tymeslot.CalendarGrid.BookablePayload do
  @moduledoc """
  Bookable windows (`Tymeslot.Availability.bookable_windows/4`, instants in
  UTC) as the calendar canvas draws them: wall-clock minutes in the
  organiser's zone ("2026-10-19T09:00"), as `EventPayload` sends events. A
  window may cross midnight; the hook splits it per day column.
  """

  @type window :: %{start_at: DateTime.t(), end_at: DateTime.t()}

  @doc "Each window as `%{start, end}` wall-clock minutes in `timezone`."
  @spec windows([window()], String.t()) :: [%{start: String.t(), end: String.t()}]
  def windows(windows, timezone), do: Enum.map(windows, &window(&1, timezone))

  @doc "One instant as a wall-clock minute in `timezone`."
  @spec wall(DateTime.t(), String.t()) :: String.t()
  def wall(datetime, timezone), do: datetime |> local(timezone) |> format()

  defp window(%{start_at: start_at, end_at: end_at}, timezone) do
    start = local(start_at, timezone)
    finish = local(end_at, timezone)

    # When the clocks go back the hour repeats, so a window inside it can end
    # on the wall clock before it starts. Keep its real length from the
    # wall-clock start instead, as `EventPayload` does for events.
    finish =
      if NaiveDateTime.compare(finish, start) == :gt,
        do: finish,
        else: NaiveDateTime.add(start, div(DateTime.diff(end_at, start_at, :second), 60), :minute)

    %{start: format(start), end: format(finish)}
  end

  defp local(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> DateTime.to_naive(shifted)
      {:error, _reason} -> DateTime.to_naive(datetime)
    end
  end

  defp format(naive), do: Calendar.strftime(naive, "%Y-%m-%dT%H:%M")
end
