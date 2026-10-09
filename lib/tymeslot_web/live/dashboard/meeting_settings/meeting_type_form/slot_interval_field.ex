defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SlotIntervalField do
  @moduledoc """
  The slot interval field of the meeting type form: which options the
  dropdown offers, when the custom number input opens, and the hint that
  previews the start times the chosen interval produces.

  Extracted from `FormView`, which renders the field and asks this module
  every question about its state. The event handlers compare submitted
  values against `custom_interval_option/0` to recognise the "Custom" choice.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  # The dropdown value that opens the custom number input. Not a duration, so
  # it can never collide with one: every real value parses as an integer.
  @custom_interval_option "custom"

  # The clock the hint's example times are drawn from. Any hour would do; a
  # round morning start reads as an illustration rather than as real data.
  @hint_start_time ~T[09:00:00]

  @doc """
  The dropdown value that opens the custom number input.
  """
  @spec custom_interval_option() :: String.t()
  def custom_interval_option, do: @custom_interval_option

  # Whether the custom number input is on screen.
  #
  # Two ways in, and both must be honoured. The organiser can pick "Custom" in
  # the dropdown, which the component records on `:custom_input_mode`. Or the
  # stored value can simply not be one this dropdown offers — written by a
  # seed, an import or a support fix — in which case the input opens on its own
  # so the value stays editable rather than being silently unreachable.
  @spec custom?(map(), term()) :: boolean()
  def custom?(assigns, current_value) do
    chosen? =
      assigns
      |> Map.get(:custom_input_mode, %{})
      |> Map.get(:slot_interval_minutes, false)

    chosen? or off_preset?(parse_interval(current_value))
  end

  defp off_preset?(nil), do: false

  defp off_preset?(interval),
    do: not CustomInputModeHelper.preset_value?(:slot_interval_minutes, interval)

  # `current_value` is whatever is currently stored/selected for this meeting
  # type. It is folded into the option list even when it falls outside the
  # preset table, so a value written by something other than this form (a seed,
  # an import, a support fix) still renders as itself instead of silently
  # falling back to "Same as meeting length" — which the next autosave of any
  # other field would then persist as the value's erasure.
  @spec options(term(), boolean()) :: [{String.t(), String.t()}]
  def options(current_value, custom?) do
    range = Constraints.slot_interval_minutes_range()

    intervals =
      :slot_interval_minutes
      |> CustomInputModeHelper.presets()
      |> Enum.filter(&(&1 in range))
      |> add_stored_interval(parse_interval(current_value), custom?)
      |> Enum.sort()
      |> Enum.map(
        &{dgettext("dashboard_meeting_form", "%{minutes} min", minutes: &1), to_string(&1)}
      )

    [{dgettext("dashboard_meeting_form", "Same as meeting length"), ""}] ++
      intervals ++
      [{dgettext("dashboard_meeting_form", "Custom…"), @custom_interval_option}]
  end

  # While the custom input is open the dropdown reads "Custom…", so folding the
  # stored value in as well would list a value nothing has selected.
  defp add_stored_interval(intervals, _interval, true), do: intervals
  defp add_stored_interval(intervals, nil, _custom?), do: intervals
  defp add_stored_interval(intervals, interval, _custom?), do: Enum.uniq([interval | intervals])

  # Spells out what the current choice produces. An interval is an abstraction
  # until it is three clock times, and five minutes is a very different booking
  # page from sixty; this is where an organiser sees which one they picked.
  #
  # A type that offers several lengths and leaves the interval on its default
  # gets a grid whose *step* is whatever length the booker picked, so the same
  # day offers different start times per length. That is defensible for a
  # single length and surprising for several, so the host is told once the
  # second length exists — and only while no fixed interval is set, because
  # setting one is the fix.
  @spec hint(term(), term(), list()) :: String.t()
  def hint(interval_value, duration_value, extra_lengths \\ []) do
    interval = parse_in_range(interval_value, Constraints.slot_interval_minutes_range())
    duration = parse_in_range(duration_value, Constraints.duration_minutes_range())

    case {interval, duration} do
      {nil, _duration} when extra_lengths != [] ->
        dgettext(
          "dashboard_meeting_form",
          "Start times follow whichever length the booker picks, so each length offers a different set of times. Choose a fixed interval to offer the same start times for every length."
        )

      {minutes, _duration} when is_integer(minutes) ->
        dgettext(
          "dashboard_meeting_form",
          "Times will be offered every %{minutes} minutes: %{examples}…",
          minutes: minutes,
          examples: interval_examples(minutes)
        )

      {nil, minutes} when is_integer(minutes) ->
        dgettext(
          "dashboard_meeting_form",
          "Matching the meeting length, times will be offered every %{minutes} minutes: %{examples}…",
          minutes: minutes,
          examples: interval_examples(minutes)
        )

      _no_valid_value ->
        dgettext(
          "dashboard_meeting_form",
          "How far apart booking start times are offered. Leave as default to match the meeting length."
        )
    end
  end

  # Steps through real datetimes rather than a bare time of day: once an
  # interval reaches twelve hours the clock repeats itself, so a time on a
  # later day carries a marker instead of reading as a duplicate.
  defp interval_examples(minutes) do
    start = NaiveDateTime.new!(~D[2000-01-01], @hint_start_time)

    start
    |> Stream.iterate(&NaiveDateTime.add(&1, minutes, :minute))
    |> Enum.take(3)
    |> Enum.map_join(", ", &format_example(&1, Date.diff(NaiveDateTime.to_date(&1), start)))
  end

  defp format_example(datetime, 0),
    do: LocalizationHelpers.format_time_by_locale(NaiveDateTime.to_time(datetime))

  defp format_example(datetime, days) do
    dngettext(
      "dashboard_meeting_form",
      "%{time} (+%{count} day)",
      "%{time} (+%{count} days)",
      days,
      time: LocalizationHelpers.format_time_by_locale(NaiveDateTime.to_time(datetime))
    )
  end

  # A blank (or the "Custom" mode before a number is typed) means no value of
  # its own; an out-of-range number is one the form is already rejecting, so it
  # has no schedule worth previewing and must not fall back to another one.
  defp parse_in_range(value, range) do
    case parse_interval(value) do
      nil -> nil
      minutes -> if minutes in range, do: minutes, else: :invalid
    end
  end

  defp parse_interval(value) when is_integer(value), do: value

  defp parse_interval(value) when is_binary(value) do
    case Integer.parse(value) do
      {interval, ""} -> interval
      _invalid -> nil
    end
  end

  defp parse_interval(_value), do: nil
end
