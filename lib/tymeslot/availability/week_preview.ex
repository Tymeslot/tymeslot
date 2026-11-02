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
  the blocks. Each block is clipped to the host's open windows for its day, as
  `Tymeslot.Availability.BusinessHours.owner_windows/4` resolves them (date
  overrides, extra windows and overnight hours included), so an evening event
  does not stretch the day and a day the host is closed has no blocks. Where
  windows overlap the blocks are merged. An overnight window's block is drawn
  on the date the window opens and stops at midnight.

  A profile whose timezone is blank or not a real zone is previewed in the
  business default zone, as the booking page treats it
  (`Tymeslot.Profiles.timezone/1`).
  """

  alias Tymeslot.Availability.Offer
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

  `first_busy` is the earliest busy block that has not ended yet, so a block
  under way counts; its `start` is when the block began within the open hours.
  """
  @spec build(ProfileSchema.t(), keyword()) :: {:ok, t()} | {:error, :calendar_unavailable}
  def build(%ProfileSchema{} = profile, opts \\ []) do
    timezone = Profiles.timezone(profile)
    now = Clock.utc_now()

    today =
      Keyword.get_lazy(opts, :today, fn ->
        now |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
      end)

    meeting_type =
      Keyword.get_lazy(opts, :meeting_type, fn ->
        profile.user_id |> MeetingTypes.get_active_meeting_types() |> List.first()
      end)

    request = %{profile: profile, user_timezone: timezone, meeting_type: meeting_type}
    duration = Offer.duration_minutes(meeting_type, @fallback_duration_minutes)

    case Offer.slots_and_busy_for_range(request, today, Date.add(today, @days - 1), duration) do
      {:ok, view} -> {:ok, assemble(view, timezone, today, now)}
      {:error, _reason} -> {:error, :calendar_unavailable}
    end
  end

  defp assemble(view, timezone, today, now) do
    blocks =
      for date <- Date.range(today, Date.add(today, @days - 1)) do
        {date, day_blocks(view, date, timezone)}
      end

    days =
      for {date, day_blocks} <- blocks do
        %{
          date: date,
          slots: view.starts |> Map.get(Date.to_iso8601(date), []) |> Enum.map(&slot_label/1),
          busy: for({from, to} <- day_blocks, do: {DateTime.to_time(from), DateTime.to_time(to)})
        }
      end

    %__MODULE__{
      days: days,
      slot_count: days |> Enum.map(&length(&1.slots)) |> Enum.sum(),
      first_busy: first_busy(blocks, now)
    }
  end

  # The earliest block that has not ended; blocks are in start order per day.
  defp first_busy(blocks, now) do
    Enum.find_value(blocks, fn {date, day_blocks} ->
      Enum.find_value(day_blocks, fn {from, to} ->
        if DateTime.compare(to, now) == :gt, do: %{date: date, start: DateTime.to_time(from)}
      end)
    end)
  end

  # The busy periods inside the open windows of `date`, in host-local time,
  # clipped to each window, sorted and merged.
  defp day_blocks(view, date, timezone) do
    for %{date: ^date} = window <- view.windows,
        window_start = DateTime.shift_zone!(window.start_dt, timezone),
        window_end = day_end(DateTime.shift_zone!(window.end_dt, timezone), date),
        {from, to} <- view.busy,
        from = latest(DateTime.shift_zone!(from, timezone), window_start),
        to = earliest(DateTime.shift_zone!(to, timezone), window_end),
        DateTime.compare(from, to) == :lt do
      {from, to}
    end
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.reduce([], &merge_block/2)
    |> Enum.reverse()
  end

  # An overnight window is drawn up to midnight on the date it opens.
  defp day_end(window_end, date) do
    if Date.compare(DateTime.to_date(window_end), date) == :gt,
      do: DateTime.new!(date, ~T[23:59:59], window_end.time_zone),
      else: window_end
  end

  defp merge_block({from, to}, [{prev_from, prev_to} | rest]) do
    if DateTime.compare(from, prev_to) == :gt,
      do: [{from, to}, {prev_from, prev_to} | rest],
      else: [{prev_from, latest(prev_to, to)} | rest]
  end

  defp merge_block(block, []), do: [block]

  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp slot_label(%DateTime{} = start), do: Calendar.strftime(start, "%H:%M")
end
