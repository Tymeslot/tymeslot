defmodule Tymeslot.CalendarGrid.AllDay do
  @moduledoc """
  Converting a calendar event between all-day and timed.

  The two representations do not overlap: an all-day event carries
  `start_date`/`end_date` and no timestamps, a timed one carries
  `start_at`/`end_at` and no dates. Toggling therefore has to *derive* one from
  the other rather than set a flag.

  ## The exclusive end date

  `end_date` is stored exclusively, matching the iCal, Google and Outlook
  all-day convention and the grid's render filter, so a single-day all-day
  event has `end_date == start_date + 1`. Every conversion here translates
  between that exclusive boundary and the inclusive last day a timed event
  touches. Getting this wrong by one day is the classic all-day bug, which is
  why it lives in one place with the convention written down.

  ## Timezone handling

  Going from all-day to timed needs a wall-clock time, and 09:00-10:00 local is
  the arbitrary but reasonable default. A DST gap or ambiguity at those hours is
  extremely unlikely, and this is a programmatic toggle rather than something
  the user typed, so it resolves gracefully rather than failing, by the shared
  rule in `Tymeslot.Utils.DateTimeUtils.resolve_local/3`: a gap resolves to its
  end, an ambiguous time to its first occurrence.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @typedoc "Any struct or map carrying the grid's event fields."
  @type event :: map()

  @default_start_time ~T[09:00:00.000000]
  @default_end_time ~T[10:00:00.000000]

  @doc """
  The calendar date an event begins on, whichever representation it carries:
  an all-day event's `start_date`, or the date a timed event's `start_at`
  falls on in `timezone` (UTC when `nil`). `nil` when it carries neither.

  A series starting at 00:30 in Berlin starts on that day, not on the UTC
  day before, so the zone is the one the series is read in.

  Reads the fields with `Map.get/2` so it also works on a schema struct, which
  has no Access behaviour.
  """
  @spec start_date(event(), String.t() | nil) :: Date.t() | nil
  def start_date(event, timezone) do
    case {Map.get(event, :start_date), Map.get(event, :start_at)} do
      {%Date{} = date, _start_at} -> date
      {_no_date, %DateTime{} = start_at} -> local_date(start_at, timezone)
      _neither -> nil
    end
  end

  @doc """
  Toggles an event between all-day and timed, deriving the new representation.
  """
  @spec toggle(event(), String.t()) :: event()
  def toggle(event, timezone)

  def toggle(%{all_day: true} = event, timezone) do
    start_date = event.start_date
    last_day = last_day(start_date, event.end_date)

    %{
      event
      | all_day: false,
        start_at: default_instant(start_date, @default_start_time, timezone),
        end_at: default_instant(last_day, @default_end_time, timezone),
        start_date: nil,
        end_date: nil
    }
  end

  # `end_at` is exclusive too: an event ending at local midnight covers no part
  # of the day that midnight begins, so its last day is the one before.
  def toggle(event, timezone) do
    start_date = local_date(event.start_at, timezone)

    last_day =
      if DateTime.after?(event.end_at, event.start_at),
        do: event.end_at |> DateTime.add(-1, :microsecond) |> local_date(timezone),
        else: start_date

    %{
      event
      | all_day: true,
        start_date: start_date,
        end_date: exclusive_end_date(last_day),
        start_at: nil,
        end_at: nil
    }
  end

  defp local_date(instant, nil), do: DateTime.to_date(instant)

  defp local_date(instant, timezone),
    do: instant |> DateTime.shift_zone!(timezone) |> DateTime.to_date()

  @spec default_instant(Date.t(), Time.t(), String.t()) :: DateTime.t()
  defp default_instant(date, time, timezone) do
    {:ok, local} = DateTimeUtils.resolve_local(date, time, timezone)
    DateTime.shift_zone!(local, "Etc/UTC")
  end

  @doc """
  The last day an all-day event actually covers, from its `start_date` and
  exclusive `end_date`. Guards against a stored `end_date` that is not after
  `start_date`, which would otherwise yield a last day before the event began.
  """
  @spec last_day(Date.t(), Date.t()) :: Date.t()
  def last_day(start_date, end_date) do
    last_day = Date.add(end_date, -1)
    if Date.compare(last_day, start_date) == :lt, do: start_date, else: last_day
  end

  # The exclusive `end_date` to store for an event whose last covered day is
  # `last_day`.
  @spec exclusive_end_date(Date.t()) :: Date.t()
  defp exclusive_end_date(last_day), do: Date.add(last_day, 1)
end
