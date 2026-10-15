defmodule Tymeslot.Availability.Window do
  @moduledoc """
  Wall-clock arithmetic for one day's availability window, which may end on
  the next day.

  A window is a start time, an end time and `ends_next_day`. Not flagged, the
  end is later the same day. Flagged, the end is on the following day and at or
  before the start, so `00:00`–`00:00` flagged is a full 24 hours and no window
  is ever longer. That bound is what lets breaks carry no day of their own:
  inside a window every wall-clock time names exactly one instant, a time at or
  after the start being on the window's date and an earlier one on the next.

  Every reader of a window goes through here (the schemas, the break rules,
  the slot engine and the editor's wire format), so what "+1" means has one
  answer. Same-day windows keep exactly the rules they had before overnight
  windows existed.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @day_seconds 86_400
  @next_day_suffix "+1"

  @type t :: %{
          required(:start_time) => Time.t(),
          required(:end_time) => Time.t(),
          required(:ends_next_day) => boolean(),
          optional(atom()) => term()
        }

  @doc "Whether the times and flag describe a window longer than zero and at most 24 hours."
  @spec valid?(Time.t(), Time.t(), boolean()) :: boolean()
  def valid?(%Time{} = start_time, %Time{} = end_time, false),
    do: Time.compare(end_time, start_time) == :gt

  def valid?(%Time{} = start_time, %Time{} = end_time, true),
    do: Time.compare(end_time, start_time) != :gt

  @doc "The length of a valid window, in seconds."
  @spec span_seconds(t()) :: pos_integer()
  def span_seconds(%{start_time: start_time, end_time: end_time, ends_next_day: true}),
    do: @day_seconds - Time.diff(start_time, end_time)

  def span_seconds(%{start_time: start_time, end_time: end_time}),
    do: Time.diff(end_time, start_time)

  @doc """
  A break's start and end as seconds from the window's start.

  In a same-day window these are plain differences, negative before the
  start, which keeps the same-day rules exactly as they were. In an overnight
  window each time is read on whichever day puts it at or after the start; an
  end that lands back on the start is the window's full length.
  """
  @spec break_offsets(t(), Time.t(), Time.t()) :: {integer(), integer()}
  def break_offsets(
        %{ends_next_day: true, start_time: window_start},
        %Time{} = from,
        %Time{} = to
      ) do
    {offset(window_start, from), end_offset(offset(window_start, to))}
  end

  def break_offsets(%{start_time: window_start}, %Time{} = from, %Time{} = to),
    do: {Time.diff(from, window_start), Time.diff(to, window_start)}

  @doc "Whether a break starts no earlier than the window, ends no later, and is not empty or reversed."
  @spec break_within?(t(), Time.t(), Time.t()) :: boolean()
  def break_within?(window, %Time{} = from, %Time{} = to) do
    {from_offset, to_offset} = break_offsets(window, from, to)
    from_offset >= 0 and from_offset < to_offset and to_offset <= span_seconds(window)
  end

  @doc """
  Whether `time`, read as a break's `:start` or `:end` inside `window`, falls
  on the day after the window's date. Always false for a same-day window.
  """
  @spec next_day?(t() | map(), Time.t(), :start | :end) :: boolean()
  def next_day?(
        %{ends_next_day: true, start_time: %Time{} = window_start},
        %Time{} = time,
        :start
      ),
      do: Time.compare(time, window_start) == :lt

  def next_day?(%{ends_next_day: true, start_time: %Time{} = window_start}, %Time{} = time, :end),
    do: Time.compare(time, window_start) != :gt

  def next_day?(_window, _time, _edge), do: false

  @doc """
  The window as instants in `timezone`, opening on `date`.

  Times are read to the minute: slots are offered and booked by
  minute-precision labels. Wall-clock times are resolved as everywhere else
  (`DateTimeUtils.create_datetime_safe/3`): a time in a spring-forward gap
  becomes the end of the gap, a repeated one its first occurrence.
  """
  @spec resolve(t(), Date.t(), String.t()) :: {DateTime.t(), DateTime.t()}
  def resolve(%{start_time: start_time, end_time: end_time} = window, date, timezone) do
    end_date = if window.ends_next_day, do: Date.add(date, 1), else: date
    {at(date, start_time, timezone), at(end_date, end_time, timezone)}
  end

  @doc """
  A break of `window` as instants, for the window opening on `date`. `window`
  may be a weekly row with no hours (a day switched off); its breaks then stay
  on `date`, as they always did.
  """
  @spec resolve_break(t() | map(), {Time.t(), Time.t()}, Date.t(), String.t()) ::
          {DateTime.t(), DateTime.t()}
  def resolve_break(window, {from, to}, date, timezone) do
    {at(day_of(window, from, :start, date), from, timezone),
     at(day_of(window, to, :end, date), to, timezone)}
  end

  @doc """
  Reads the editor's end value: `"HH:MM"` is the same day, `"HH:MM+1"` the
  next.
  """
  @spec parse_end(String.t()) :: {:ok, {Time.t(), boolean()}} | {:error, :invalid_time_format}
  def parse_end(value) when is_binary(value) do
    {clock, next_day?} =
      case String.replace_suffix(value, @next_day_suffix, "") do
        ^value -> {value, false}
        clock -> {clock, true}
      end

    case DateTimeUtils.parse_hhmm(clock) do
      {:ok, time} -> {:ok, {time, next_day?}}
      {:error, _reason} -> {:error, :invalid_time_format}
    end
  end

  @doc "Writes an end in the editor's format; the inverse of `parse_end/1`."
  @spec format_end(Time.t() | nil, boolean()) :: String.t()
  def format_end(nil, _ends_next_day), do: ""

  def format_end(%Time{} = time, ends_next_day) do
    Calendar.strftime(time, "%H:%M") <> if(ends_next_day, do: @next_day_suffix, else: "")
  end

  defp day_of(window, time, edge, date) do
    if next_day?(window, time, edge), do: Date.add(date, 1), else: date
  end

  defp at(date, time, timezone),
    do:
      DateTimeUtils.create_datetime_safe(date, %{time | second: 0, microsecond: {0, 0}}, timezone)

  defp offset(window_start, time), do: Integer.mod(Time.diff(time, window_start), @day_seconds)

  defp end_offset(0), do: @day_seconds
  defp end_offset(offset), do: offset
end
