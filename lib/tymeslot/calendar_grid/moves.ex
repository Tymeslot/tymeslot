defmodule Tymeslot.CalendarGrid.Moves do
  @moduledoc """
  The timing rules every change to when an event happens follows, whoever
  draws it: a drag or resize on the grid, a keyboard move, quick create and
  the side panel.

    * **What can be drawn.** A timed event lasts more than nothing and at
      most a week (`max_span_seconds/0`), and starts in the years the grid
      can show (`years/0`).
    * **What an all-day event can span.** From one day to a year and a day
      (`max_all_day_days/0`), in the same years (`sensible_days?/2`).
    * **Wall clock to instant.** The client speaks in wall-clock minutes
      (`"2026-10-15T11:00"`) in the organiser's zone; each is resolved
      across a clock change as every other wall-clock conversion is
      (`Tymeslot.Utils.DateTimeUtils.resolve_local/3`): a time a
      spring-forward gap skips becomes the end of the gap, a time a
      fall-back overlap repeats its first occurrence.
    * **Move or resize.** When the wall-clock span drawn is the span the
      event has on the wall, it is a move, and the event keeps its real
      length, so a clock change between the old and the new day cannot
      stretch or shrink it. Otherwise it is a resize, and the end is the
      wall-clock end drawn. An event that itself spans a clock change keeps
      its real duration, so on an ordinary day it shows an hour longer or
      shorter on the wall.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @max_span_seconds 7 * 86_400
  @max_all_day_days 366
  @years 1900..2200

  @typedoc "A wall-clock minute as the client sends it: `\"YYYY-MM-DDTHH:MM\"`."
  @type wall :: String.t()

  @doc "The longest a timed event may last, in seconds: one week."
  @spec max_span_seconds() :: pos_integer()
  def max_span_seconds, do: @max_span_seconds

  @doc "The years a timed event may start in."
  @spec years() :: Range.t()
  def years, do: @years

  @doc "The most days an all-day event may cover."
  @spec max_all_day_days() :: pos_integer()
  def max_all_day_days, do: @max_all_day_days

  @doc """
  The instant the wall-clock minute `wall` names in `timezone`, resolved
  across a clock change (see the moduledoc). `:error` for text that is not a
  wall-clock minute, or a zone that does not exist.
  """
  @spec wall_to_utc(wall() | term(), String.t()) :: {:ok, DateTime.t()} | :error
  def wall_to_utc(wall, timezone) when is_binary(wall) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(wall <> ":00"),
         time = Time.new!(naive.hour, naive.minute, 0, {0, 6}),
         {:ok, local} <- DateTimeUtils.resolve_local(NaiveDateTime.to_date(naive), time, timezone) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    else
      _invalid -> :error
    end
  end

  def wall_to_utc(_wall, _timezone), do: :error

  @doc """
  Whether a timed event from `start_at` to `end_at` can be drawn: it ends
  after it starts, lasts at most `max_span_seconds/0`, and starts in
  `years/0`.
  """
  @spec sensible?(DateTime.t(), DateTime.t()) :: boolean()
  def sensible?(%DateTime{} = start_at, %DateTime{} = end_at) do
    span = DateTime.diff(end_at, start_at)
    span > 0 and span <= @max_span_seconds and start_at.year in @years
  end

  @doc """
  Whether an all-day event from `first` to the exclusive `after_last` can be
  drawn: it covers 1 to `max_all_day_days/0` days, and starts and ends in
  `years/0`.
  """
  @spec sensible_days?(Date.t(), Date.t()) :: boolean()
  def sensible_days?(%Date{} = first, %Date{} = after_last) do
    days = Date.diff(after_last, first)

    days >= 1 and days <= @max_all_day_days and first.year in @years and
      after_last.year in @years
  end

  @doc """
  The timing a timed `event` takes when it is drawn from `start_wall` to
  `end_wall` in `timezone`: a move keeps the event's real length, a resize
  takes the drawn end (see the moduledoc). `{:error, :out_of_range}` when
  the event would start outside `years/0`; `{:error, :invalid_time}` when
  either wall clock cannot be read, or the result is otherwise not
  `sensible?/2`.
  """
  @spec resolve(map(), wall(), wall(), String.t()) ::
          {:ok, %{start_at: DateTime.t(), end_at: DateTime.t()}}
          | {:error, :invalid_time | :out_of_range}
  def resolve(
        %{start_at: %DateTime{}, end_at: %DateTime{}} = event,
        start_wall,
        end_wall,
        timezone
      )
      when is_binary(start_wall) and is_binary(end_wall) do
    with {:ok, start_at} <- wall_to_utc(start_wall, timezone),
         {:ok, end_at} <- end_at(event, start_wall, end_wall, start_at, timezone),
         :ok <- in_years(start_at),
         true <- sensible?(start_at, end_at) do
      {:ok, %{start_at: start_at, end_at: end_at}}
    else
      {:error, :out_of_range} -> {:error, :out_of_range}
      _invalid -> {:error, :invalid_time}
    end
  end

  def resolve(_event, _start_wall, _end_wall, _timezone), do: {:error, :invalid_time}

  defp in_years(%DateTime{year: year}),
    do: if(year in @years, do: :ok, else: {:error, :out_of_range})

  defp end_at(event, start_wall, end_wall, start_at, timezone) do
    with {:ok, drawn_start} <- NaiveDateTime.from_iso8601(start_wall <> ":00"),
         {:ok, drawn_end} <- NaiveDateTime.from_iso8601(end_wall <> ":00") do
      if NaiveDateTime.diff(drawn_end, drawn_start) == wall_length(event, timezone),
        do: {:ok, DateTime.add(start_at, DateTime.diff(event.end_at, event.start_at))},
        else: wall_to_utc(end_wall, timezone)
    else
      _invalid -> :error
    end
  end

  defp wall_length(event, timezone) do
    NaiveDateTime.diff(
      event.end_at |> DateTime.shift_zone!(timezone) |> DateTime.to_naive(),
      event.start_at |> DateTime.shift_zone!(timezone) |> DateTime.to_naive()
    )
  end
end
