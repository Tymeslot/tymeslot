defmodule Tymeslot.Meetings.BookingLimits do
  @moduledoc """
  Pure logic for booking limits: caps on how many bookings a host accepts
  per day, week, and month.

  Two axes compose, each with daily/weekly/monthly caps:

    * account-wide caps, stored on the host's profile
    * per-meeting-type caps, stored on the meeting type

  A booking instant passes only when every configured cap still has room.
  Limits count Tymeslot bookings that hold a slot (see
  `Tymeslot.Meetings.MeetingState.where_slot_live/1`) — never external
  calendar events, which are conflict-checking's concern.

  Period boundaries resolve in the host's timezone (the limit protects the
  host), with weeks starting on Monday. All functions here are pure; rows
  come from `Tymeslot.Meetings.MeetingQueries.list_live_booking_starts/4`,
  and `Tymeslot.Meetings.BookingLimits.Checker` wires the two together.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @week_start :monday

  @type caps :: %{day: pos_integer() | nil, week: pos_integer() | nil, month: pos_integer() | nil}
  @type limits :: %{account: caps(), per_type: caps(), meeting_type_id: integer() | nil}
  @type booking_row :: %{start_time: DateTime.t(), meeting_type_id: integer() | nil}
  @type period_key :: {:day | :week | :month, Date.t()}
  @type context :: %{
          limits: limits(),
          host_timezone: String.t(),
          account_counts: %{period_key() => non_neg_integer()},
          type_counts: %{period_key() => non_neg_integer()}
        }

  @doc """
  Extracts the applicable caps from a profile (or settings map) and an
  optional meeting type. Missing keys and `nil` sources mean "no cap".
  """
  @spec limits_for(map() | nil, map() | nil) :: limits()
  def limits_for(profile_settings, meeting_type) do
    %{
      account: caps_from(profile_settings),
      per_type: caps_from(meeting_type),
      meeting_type_id: meeting_type && Map.get(meeting_type, :id)
    }
  end

  @doc "Whether any cap is configured. Callers can skip all work when false."
  @spec enabled?(limits()) :: boolean()
  def enabled?(%{account: account, per_type: per_type}) do
    Enum.any?(Map.values(account)) or Enum.any?(Map.values(per_type))
  end

  @doc "The host-timezone calendar day containing the given instant."
  @spec day_key(DateTime.t(), String.t()) :: Date.t()
  def day_key(%DateTime{} = instant, host_timezone) do
    instant
    |> DateTimeUtils.convert_to_timezone(host_timezone)
    |> DateTime.to_date()
  end

  @doc "The Monday starting the host-timezone week containing the instant."
  @spec week_key(DateTime.t(), String.t()) :: Date.t()
  def week_key(%DateTime{} = instant, host_timezone) do
    instant
    |> day_key(host_timezone)
    |> Date.beginning_of_week(@week_start)
  end

  @doc "The first day of the host-timezone month containing the instant."
  @spec month_key(DateTime.t(), String.t()) :: Date.t()
  def month_key(%DateTime{} = instant, host_timezone) do
    instant
    |> day_key(host_timezone)
    |> Date.beginning_of_month()
  end

  @doc """
  The UTC window whose bookings can affect any day/week/month cap that a
  date in `start_date..end_date` falls under.

  Pads the range by one day first (a booker-timezone day can straddle two
  host-timezone days), then widens to the enclosing Monday-weeks and
  calendar months. Weekly and monthly caps are judged on the full enclosing
  period, even the parts outside the displayed or bookable range.
  Returns `{from_utc, to_utc}` with `to_utc` exclusive.
  """
  @spec expanded_query_window(Date.t(), Date.t(), String.t()) :: {DateTime.t(), DateTime.t()}
  def expanded_query_window(%Date{} = start_date, %Date{} = end_date, host_timezone) do
    padded_start = Date.add(start_date, -1)
    padded_end = Date.add(end_date, 1)

    from_date =
      Enum.min(
        [
          Date.beginning_of_week(padded_start, @week_start),
          Date.beginning_of_month(padded_start)
        ],
        Date
      )

    to_date =
      Enum.max(
        [Date.end_of_week(padded_end, @week_start), Date.end_of_month(padded_end)],
        Date
      )

    {host_midnight_utc(from_date, host_timezone),
     host_midnight_utc(Date.add(to_date, 1), host_timezone)}
  end

  @doc """
  Buckets booking rows into per-period counts for both axes. Type counts
  only accumulate rows matching `limits.meeting_type_id`.
  """
  @spec build_context(limits(), String.t(), [booking_row()]) :: context()
  def build_context(limits, host_timezone, rows) do
    account_counts =
      Enum.reduce(rows, %{}, fn row, acc -> bump_periods(acc, row.start_time, host_timezone) end)

    type_counts =
      rows
      |> Enum.filter(
        &(&1.meeting_type_id == limits.meeting_type_id and not is_nil(limits.meeting_type_id))
      )
      |> Enum.reduce(%{}, fn row, acc -> bump_periods(acc, row.start_time, host_timezone) end)

    %{
      limits: limits,
      host_timezone: host_timezone,
      account_counts: account_counts,
      type_counts: type_counts
    }
  end

  @doc """
  Whether a candidate booking at `instant` would exceed any configured cap.
  """
  @spec slot_blocked?(context(), DateTime.t()) :: boolean()
  def slot_blocked?(context, %DateTime{} = instant) do
    keys = period_keys(instant, context.host_timezone)

    axis_blocked?(context.limits.account, context.account_counts, keys) or
      axis_blocked?(context.limits.per_type, context.type_counts, keys)
  end

  @doc """
  Booking-time form of `slot_blocked?/2`.
  """
  @spec check_booking_allowed(context(), DateTime.t()) :: :ok | {:error, :booking_limit_reached}
  def check_booking_allowed(context, %DateTime{} = instant) do
    if slot_blocked?(context, instant) do
      {:error, :booking_limit_reached}
    else
      :ok
    end
  end

  defp caps_from(nil), do: %{day: nil, week: nil, month: nil}

  defp caps_from(source) do
    %{
      day: Map.get(source, :max_bookings_per_day),
      week: Map.get(source, :max_bookings_per_week),
      month: Map.get(source, :max_bookings_per_month)
    }
  end

  defp period_keys(instant, host_timezone) do
    day = day_key(instant, host_timezone)

    %{
      day: {:day, day},
      week: {:week, Date.beginning_of_week(day, @week_start)},
      month: {:month, Date.beginning_of_month(day)}
    }
  end

  defp bump_periods(counts, start_time, host_timezone) do
    start_time
    |> period_keys(host_timezone)
    |> Map.values()
    |> Enum.reduce(counts, fn key, acc -> Map.update(acc, key, 1, &(&1 + 1)) end)
  end

  defp axis_blocked?(caps, counts, keys) do
    Enum.any?([:day, :week, :month], fn period ->
      case caps[period] do
        nil -> false
        cap -> Map.get(counts, keys[period], 0) >= cap
      end
    end)
  end

  defp host_midnight_utc(date, host_timezone) do
    date
    |> DateTimeUtils.create_datetime_safe(~T[00:00:00], host_timezone)
    |> DateTimeUtils.convert_to_timezone("Etc/UTC")
  end
end
