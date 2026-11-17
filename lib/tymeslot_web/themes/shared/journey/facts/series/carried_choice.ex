defmodule TymeslotWeb.Themes.Shared.Journey.Facts.Series.CarriedChoice do
  @moduledoc """
  The series choice as the page's URL carries it (`series`), so a reconnect
  or a language switch keeps it (`Journey.Facts.Series`).

  The value is `single`, a recurring series' count (`6`), or a flexible
  series' later sessions as minutes after the first (`f.10080.20160`, just
  `f` for the first alone); `to_param/1` writes it and
  `PathHandlers.choices_query/1` puts it in the URL. A page arriving with
  one keeps it for the slot the URL names (`carry/2`, `:carried_series`),
  and the series moment makes its choice from it when it opens
  (`restore/3`) in place of the default.

  It is visitor input: a count outside the type's range, a session before
  the first or past the series' span, more sessions than the type takes,
  or a single session where the type needs a series gives the default
  instead, and a carried flexible session the first check finds
  unavailable is dropped (`drop_lost/3`, while `:series_restoring` names
  that check).
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.BookingSeries.Check
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.MeetingTypes.SeriesSettings
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Series
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Series.Preview

  # The longest `series` value a page reads back: "f" and up to 25 later
  # sessions of at most six digits each fit well inside it.
  @max_param_bytes 256

  @doc """
  The choice as the page's URL carries it (`series`), or nil: nothing
  chosen, a booking that does not need the fact, or a choice made for
  another first session than the slot now picked.
  """
  @spec to_param(map()) :: String.t() | nil
  def to_param(assigns) do
    case {Series.required?(assigns), assigns[:series_choice]} do
      {true, :single} -> "single"
      {true, %{} = choice} -> if for_slot?(assigns, choice), do: encode(choice)
      _none -> nil
    end
  end

  defp for_slot?(assigns, %{starts: [first | _rest]}) do
    case Series.first_start(assigns) do
      %DateTime{} = picked -> DateTime.compare(first, picked) == :eq
      nil -> false
    end
  end

  defp encode(%{mode: :recurring, count: count}), do: Integer.to_string(count)

  defp encode(%{mode: :flexible, starts: [first | rest]}),
    do:
      Enum.map_join(["f" | Enum.map(rest, &DateTime.diff(&1, first, :minute))], ".", &to_string/1)

  @doc """
  Keeps the `series` value a page arrived with (`to_param/1`) for the slot
  the page now holds, so the moment, when it opens for that slot, makes the
  choice from it. Applied with the rest of the URL
  (`LiveHelpers.Mount.handle_param_updates/2`), after the slot.
  """
  @spec carry(Socket.t(), term()) :: Socket.t()
  def carry(socket, value) when is_binary(value) and byte_size(value) <= @max_param_bytes do
    assign(socket, :carried_series, %{
      value: value,
      date: socket.assigns[:selected_date],
      time: socket.assigns[:selected_time]
    })
  end

  def carry(socket, _value), do: assign(socket, :carried_series, nil)

  @doc """
  The choice `carried` (`carry/2`) names for the first session `first`, or
  `:error` when it was carried for another slot or the meeting type would
  not offer it.
  """
  @spec restore(map() | nil, map(), DateTime.t()) :: {:ok, Series.choice()} | :error
  def restore(
        %{value: value, date: date, time: time},
        %{selected_date: date, selected_time: time} = assigns,
        first
      )
      when is_binary(date) and is_binary(time),
      do: decode(value, assigns, first)

  def restore(_carried, _assigns, _first), do: :error

  defp decode("single", assigns, _first),
    do: if(assigns[:series_single_allowed?] == true, do: {:ok, :single}, else: :error)

  defp decode("f" <> offsets, %{meeting_type: %{series_mode: :flexible} = type}, first) do
    with {:ok, minutes} <- parse_offsets(offsets, type.series_max_occurrences - 1) do
      later = minutes |> Enum.uniq() |> Enum.sort() |> Enum.map(&DateTime.add(first, &1, :minute))
      {:ok, %{mode: :flexible, starts: [first | later], count: length(later) + 1}}
    end
  end

  defp decode(value, %{meeting_type: %{series_mode: :recurring} = type}, first) do
    with {count, ""} <- Integer.parse(value),
         true <- count in SeriesSettings.count_range(type) do
      {:ok, %{mode: :recurring, starts: [first], count: count}}
    else
      _invalid -> :error
    end
  end

  defp decode(_value, _assigns, _first), do: :error

  # At most `max` sessions after the first, each after it and within the
  # series' span.
  defp parse_offsets("", _max), do: {:ok, []}

  defp parse_offsets("." <> list, max) when max > 0 do
    parts = String.split(list, ".", parts: max + 1)
    span = Check.span_days() * 24 * 60

    if length(parts) <= max do
      Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, minutes} ->
        case Integer.parse(part) do
          {minute, ""} when minute > 0 and minute <= span -> {:cont, {:ok, [minute | minutes]}}
          _invalid -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp parse_offsets(_offsets, _max), do: :error

  @doc """
  A check's answer for a flexible choice the URL carried (the check
  `:series_restoring` names) keeps only the later sessions it finds
  available: a session no longer offered is dropped on arrival, as a
  carried time is. Dropping a session changes no other's answer (only
  available sessions count towards the series' overlaps and limits), so
  the rest are renumbered rather than checked again. Returns the socket,
  the key and the occurrences the answer stands for.
  """
  @spec drop_lost(Socket.t(), tuple(), [Occurrence.t()]) ::
          {Socket.t(), tuple(), [Occurrence.t()]}
  def drop_lost(%{assigns: %{series_restoring: key}} = socket, key, occurrences) do
    {kept, lost} = Enum.split_with(occurrences, &(&1.position == 1 or &1.status == :available))

    if lost == [] do
      {socket, key, occurrences}
    else
      kept =
        kept |> Enum.with_index(1) |> Enum.map(fn {o, position} -> %{o | position: position} end)

      starts = Enum.map(kept, & &1.start)
      choice = %{socket.assigns.series_choice | starts: starts, count: length(starts)}
      {assign(socket, :series_choice, choice), Preview.key(choice), kept}
    end
  end

  def drop_lost(socket, key, occurrences), do: {socket, key, occurrences}
end
