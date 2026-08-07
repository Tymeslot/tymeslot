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
  the user typed, so it resolves gracefully rather than failing: a gap uses the
  shifted time just after it, an ambiguous time picks the DST side.
  """

  @typedoc "Any struct or map carrying the grid's event fields."
  @type event :: map()

  @default_start_hour 9
  @default_end_hour 10

  @doc """
  Toggles an event between all-day and timed, deriving the new representation.

  `to_utc` converts a `(date, hour, minute, timezone)` into a UTC datetime; it
  is passed in so this module stays free of the web layer's timezone helpers.
  """
  @spec toggle(event(), String.t(), (Date.t(), non_neg_integer(), non_neg_integer(), String.t() ->
                                       {:ok, DateTime.t()})) :: event()
  def toggle(event, timezone, to_utc)

  def toggle(%{all_day: true} = event, timezone, to_utc) do
    start_date = event.start_date
    last_day = inclusive_last_day(start_date, event.end_date)

    {:ok, start_at} = to_utc.(start_date, @default_start_hour, 0, timezone)
    {:ok, end_at} = to_utc.(last_day, @default_end_hour, 0, timezone)

    %{
      event
      | all_day: false,
        start_at: start_at,
        end_at: end_at,
        start_date: nil,
        end_date: nil
    }
  end

  def toggle(event, timezone, _to_utc) do
    start_date = event.start_at |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
    last_day = event.end_at |> DateTime.shift_zone!(timezone) |> DateTime.to_date()

    %{
      event
      | all_day: true,
        start_date: start_date,
        end_date: exclusive_end_date(last_day),
        start_at: nil,
        end_at: nil
    }
  end

  @doc """
  The last day an all-day event actually covers, from its exclusive `end_date`.

  Guards against a stored `end_date` that is not after `start_date`, which would
  otherwise yield a last day before the event began.
  """
  @spec inclusive_last_day(Date.t(), Date.t()) :: Date.t()
  def inclusive_last_day(start_date, end_date) do
    last_day = Date.add(end_date, -1)
    if Date.compare(last_day, start_date) == :lt, do: start_date, else: last_day
  end

  @doc """
  The exclusive `end_date` to store for an event whose last covered day is
  `last_day`.
  """
  @spec exclusive_end_date(Date.t()) :: Date.t()
  def exclusive_end_date(last_day), do: Date.add(last_day, 1)
end
