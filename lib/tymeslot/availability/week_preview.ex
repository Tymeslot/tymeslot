defmodule Tymeslot.Availability.WeekPreview do
  @moduledoc """
  A host's next seven days as a visitor to their booking page would be offered
  them: the free slots and the busy blocks that took the rest, all in the
  host's own timezone.

  It feeds the onboarding reveal, which shows a host their real week right
  after they connect a calendar. It is a pure read: the slots come from
  `Tymeslot.Availability.Offer` (so notice, buffers, limits and overrides apply
  exactly as on the booking page) and the busy blocks from the very same
  calendar read, so the two cannot disagree and the calendar is fetched once.

  Busy blocks are for display. Buffers and minimum notice shape the slots, not
  the blocks, and each block is clipped to the host's open hours for its day,
  so an evening event does not stretch the day. A day the host is closed has no
  blocks.
  """

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Clock
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

  @days 7
  @fallback_duration_minutes 30

  @enforce_keys [:days, :slot_count, :first_busy]
  defstruct [:days, :slot_count, :first_busy]

  @type day :: %{
          date: Date.t(),
          slots: [String.t()],
          busy: [{Time.t(), Time.t()}]
        }

  @type t :: %__MODULE__{
          days: [day()],
          slot_count: non_neg_integer(),
          first_busy: %{date: Date.t(), start: Time.t()} | nil
        }

  @doc """
  Builds the preview for `profile`.

  Options: `:meeting_type` (default: the host's first active meeting type; a
  host with none is previewed with a #{@fallback_duration_minutes}-minute
  meeting and the default schedule) and `:today` (default: today's date in the
  host's timezone).
  """
  @spec build(ProfileSchema.t(), keyword()) :: {:ok, t()} | {:error, :calendar_unavailable}
  def build(%ProfileSchema{} = profile, opts \\ []) do
    timezone = Profiles.timezone(profile)
    now = Clock.utc_now()
    today = Keyword.get_lazy(opts, :today, fn -> local_date(now, timezone) end)
    last = Date.add(today, @days - 1)

    meeting_type =
      Keyword.get_lazy(opts, :meeting_type, fn ->
        profile.user_id |> MeetingTypes.get_active_meeting_types() |> List.first()
      end)

    request = %{profile: profile, user_timezone: timezone, meeting_type: meeting_type}
    duration = Offer.duration_minutes(meeting_type, @fallback_duration_minutes)

    case Offer.slots_and_busy_for_range(request, today, last, duration) do
      {:ok, %{slots: slots, busy: busy}} ->
        {:ok, assemble(profile, meeting_type, timezone, today, now, slots, busy)}

      {:error, _reason} ->
        {:error, :calendar_unavailable}
    end
  end

  defp assemble(profile, meeting_type, timezone, today, now, slots, busy) do
    schedule = Schedules.resolve_for(meeting_type, profile)

    blocks =
      for date <- Date.range(today, Date.add(today, @days - 1)) do
        {date, day_blocks(busy, date, timezone, open_hours(schedule, date))}
      end

    days =
      for {date, day_blocks} <- blocks do
        %{
          date: date,
          slots: slots |> Map.get(Date.to_iso8601(date), []) |> Enum.map(&slot_label/1),
          busy: for({from, to} <- day_blocks, do: {DateTime.to_time(from), DateTime.to_time(to)})
        }
      end

    %__MODULE__{
      days: days,
      slot_count: days |> Enum.map(&length(&1.slots)) |> Enum.sum(),
      first_busy: first_busy(blocks, now)
    }
  end

  defp first_busy(blocks, now) do
    Enum.find_value(blocks, fn {date, day_blocks} ->
      Enum.find_value(day_blocks, fn {from, _to} ->
        if DateTime.compare(from, now) != :lt,
          do: %{date: date, start: DateTime.to_time(from)}
      end)
    end)
  end

  defp local_date(now, timezone) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _reason} -> DateTime.to_date(now)
    end
  end

  # The host's open window on `date`, or nil when closed (or no schedule).
  defp open_hours(nil, _date), do: nil

  defp open_hours(%{id: schedule_id}, date) do
    case WeeklySchedule.get_day_availability(schedule_id, Date.day_of_week(date)) do
      %{is_available: true, start_time: %Time{} = from, end_time: %Time{} = to} = day ->
        {from, if(day.ends_next_day, do: ~T[23:59:59], else: to)}

      _closed ->
        nil
    end
  end

  # The busy periods overlapping the open window of `date`, clipped to it, in
  # host-local time, overlapping blocks merged and sorted.
  defp day_blocks(_busy, _date, _timezone, nil), do: []

  defp day_blocks(busy, date, timezone, {open, close}) do
    window_start = local_datetime(date, open, timezone)
    window_end = local_datetime(date, close, timezone)

    busy
    |> Enum.flat_map(fn {from, to} ->
      from = latest(DateTime.shift_zone!(from, timezone), window_start)
      to = earliest(DateTime.shift_zone!(to, timezone), window_end)
      if DateTime.compare(from, to) == :lt, do: [{from, to}], else: []
    end)
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.reduce([], &merge_block/2)
    |> Enum.reverse()
  end

  defp merge_block({from, to}, [{prev_from, prev_to} | rest]) do
    if DateTime.compare(from, prev_to) == :gt,
      do: [{from, to}, {prev_from, prev_to} | rest],
      else: [{prev_from, earliest_last(prev_to, to)} | rest]
  end

  defp merge_block(block, []), do: [block]

  defp earliest_last(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  # A wall time that does not exist (spring forward) or exists twice (fall
  # back) still names an instant for a window edge.
  defp local_datetime(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> datetime
      {:ambiguous, first, _second} -> first
      {:gap, _before, after_gap} -> after_gap
    end
  end

  defp slot_label(%{time: label}), do: slot_label(label)

  defp slot_label(label) when is_binary(label) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})\s*(AM|PM)$/i, String.trim(label)) do
      [_match, hour, minute, meridiem] ->
        hour =
          rem(String.to_integer(hour), 12) + if(String.upcase(meridiem) == "PM", do: 12, else: 0)

        "#{String.pad_leading("#{hour}", 2, "0")}:#{minute}"

      nil ->
        label
    end
  end
end
