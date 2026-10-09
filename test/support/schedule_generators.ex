defmodule Tymeslot.Test.ScheduleGenerators do
  @moduledoc """
  StreamData generators for in-memory weekly schedules, shared by the slot
  engine properties. Times are on the quarter hour, as the editor writes them.
  """

  import StreamData
  require ExUnitProperties

  # Both hemispheres' DST, a half-hour and a +13 offset, and the far west.
  @zones [
    "Etc/UTC",
    "Europe/London",
    "Europe/Berlin",
    "America/New_York",
    "America/Los_Angeles",
    "America/Santiago",
    "Asia/Kolkata",
    "Asia/Tokyo",
    "Australia/Sydney",
    "Pacific/Auckland"
  ]

  # Ordinary days and every 2027 DST transition the zones above go through.
  @dates [
    ~D[2027-01-12],
    ~D[2027-06-15],
    ~D[2027-03-14],
    ~D[2027-11-07],
    ~D[2027-03-28],
    ~D[2027-10-31],
    ~D[2027-04-04],
    ~D[2027-09-05],
    ~D[2027-09-26],
    ~D[2027-10-03]
  ]

  @spec zone() :: StreamData.t(String.t())
  def zone, do: member_of(@zones)

  @spec date() :: StreamData.t(Date.t())
  def date, do: member_of(@dates)

  @spec duration() :: StreamData.t(pos_integer())
  def duration, do: member_of([15, 30, 45, 50, 60, 90, 120, 240])

  @spec interval() :: StreamData.t(pos_integer() | nil)
  def interval, do: member_of([nil, nil, 15, 30, 45, 60, 90, 120])

  @doc "A same-day window with up to two breaks inside it, as the editor could always store."
  @spec same_day_window() :: StreamData.t(map())
  def same_day_window do
    ExUnitProperties.gen all(
                           start_q <- integer(0..94),
                           length_q <- integer(1..(95 - start_q)),
                           breaks <- breaks_within(length_q)
                         ) do
      %{
        start_time: quarter(start_q),
        end_time: quarter(start_q + length_q),
        ends_next_day: false,
        breaks:
          Enum.map(breaks, fn {from, to} ->
            %{start_time: quarter(start_q + from), end_time: quarter(start_q + to)}
          end)
      }
    end
  end

  @doc """
  A window as it could be stored before overnight hours: a same-day
  quarter-hour window, or one ending at 23:59 or 23:59:59 (never offered by the
  editor, but writable through the database), possibly with a break running to
  that end.
  """
  @spec legacy_window() :: StreamData.t(map())
  def legacy_window, do: one_of([same_day_window(), until_end_of_day_window()])

  @doc "A same-day window ending at 23:59 or 23:59:59, with breaks inside it and maybe one running to its end."
  @spec until_end_of_day_window() :: StreamData.t(map())
  def until_end_of_day_window do
    ExUnitProperties.gen all(
                           start_q <- integer(0..94),
                           end_time <- member_of([~T[23:59:00], ~T[23:59:59]]),
                           breaks <- breaks_within(95 - start_q),
                           last_break_q <- one_of([constant(nil), integer(start_q..94)])
                         ) do
      inner =
        Enum.map(breaks, fn {from, to} ->
          %{start_time: quarter(start_q + from), end_time: quarter(start_q + to)}
        end)

      to_end =
        if last_break_q, do: [%{start_time: quarter(last_break_q), end_time: end_time}], else: []

      %{
        start_time: quarter(start_q),
        end_time: end_time,
        ends_next_day: false,
        breaks: inner ++ to_end
      }
    end
  end

  @doc "A window of 15 minutes to 24 hours from any quarter hour, flagged when it runs past midnight."
  @spec any_window() :: StreamData.t(map())
  def any_window do
    ExUnitProperties.gen all(
                           start_q <- integer(0..95),
                           length_q <- integer(1..96),
                           breaks <- breaks_within(length_q)
                         ) do
      end_q = start_q + length_q

      %{
        start_time: quarter(start_q),
        end_time: quarter(rem(end_q, 96)),
        ends_next_day: end_q >= 96,
        breaks:
          Enum.map(breaks, fn {from, to} ->
            %{
              start_time: quarter(rem(start_q + from, 96)),
              end_time: quarter(rem(start_q + to, 96))
            }
          end)
      }
    end
  end

  @doc "Seven weekdays, each off or carrying a window from `window_gen`."
  @spec week(StreamData.t(map())) :: StreamData.t([map()])
  def week(window_gen) do
    1..7
    |> Enum.map(fn day ->
      one_of([
        constant(%{
          day_of_week: day,
          is_available: false,
          start_time: nil,
          end_time: nil,
          ends_next_day: false,
          breaks: []
        }),
        map(window_gen, &Map.merge(&1, %{day_of_week: day, is_available: true}))
      ])
    end)
    |> fixed_list()
  end

  @doc "Up to two overrides within three days of `around`; custom hours come from `window_gen`."
  @spec overrides(Date.t(), StreamData.t(map())) :: StreamData.t([map()])
  def overrides(around, window_gen) do
    override =
      ExUnitProperties.gen all(
                             offset <- integer(-3..3),
                             kind <- member_of(["unavailable", "custom_hours", "available"]),
                             window <- window_gen
                           ) do
        base = %{date: Date.add(around, offset), override_type: kind}

        if kind == "custom_hours",
          do: Map.merge(base, Map.take(window, [:start_time, :end_time, :ends_next_day])),
          else: base
      end

    map(list_of(override, max_length: 2), &Enum.uniq_by(&1, fn o -> o.date end))
  end

  @doc "Zero or one time-off period touching `around`, all-day or with part-day edges."
  @spec time_off(Date.t()) :: StreamData.t([map()])
  def time_off(around) do
    period =
      ExUnitProperties.gen all(
                             start_offset <- integer(-2..1),
                             days <- integer(0..2),
                             start_q <- one_of([constant(nil), integer(0..95)]),
                             end_q <- one_of([constant(nil), integer(1..95)])
                           ) do
        starts_on = Date.add(around, start_offset)

        %{
          starts_on: starts_on,
          ends_on: Date.add(starts_on, days),
          start_time: start_q && quarter(start_q),
          end_time: end_q && quarter(end_q)
        }
      end

    list_of(period, max_length: 1)
  end

  # Up to two breaks as quarter-hour offsets inside a window of `length_q`.
  defp breaks_within(length_q) when length_q < 2, do: constant([])

  defp breaks_within(length_q) do
    pair =
      ExUnitProperties.gen all(
                             from <- integer(0..(length_q - 1)),
                             len <- integer(1..(length_q - from))
                           ) do
        {from, from + len}
      end

    list_of(pair, max_length: 2)
  end

  defp quarter(q), do: Time.new!(div(q, 4), rem(q, 4) * 15, 0)
end
