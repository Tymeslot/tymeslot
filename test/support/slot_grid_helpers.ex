defmodule Tymeslot.Test.SlotGridHelpers do
  @moduledoc """
  Builds the in-memory schedule config the slot engine reads, for tests that
  need neither a database nor a clock.

  `BusinessHours` reads `:weekly_schedule`, `:overrides` and `:time_off` from
  the config whenever they are present and only queries the database when they
  are absent, so a config built here keeps every lookup in memory.
  """

  alias Tymeslot.Availability.{SlotGrid, TimeSlots}

  @schedule_id 1

  @typedoc "One weekday: `%{day_of_week:, start_time:, end_time:}` plus optional `:ends_next_day`, `:breaks`, `:is_available`."
  @type day_attrs :: map()

  @doc """
  Options: `:days` (list of `day_attrs`), `:overrides` (maps with `:date`,
  `:override_type`, optional `:start_time`, `:end_time`, `:ends_next_day`),
  `:time_off` (maps with `:starts_on`, `:ends_on`, optional `:start_time`,
  `:end_time`), `:interval` (slot interval minutes or nil).
  """
  @spec pure_config(keyword()) :: map()
  def pure_config(opts) do
    %{
      schedule_id: @schedule_id,
      weekly_schedule: opts |> Keyword.get(:days, []) |> Enum.map(&day/1),
      overrides: opts |> Keyword.get(:overrides, []) |> Enum.map(&override/1),
      time_off: Keyword.get(opts, :time_off, []),
      slot_interval_minutes: Keyword.get(opts, :interval)
    }
  end

  @doc "The same hours on all seven weekdays."
  @spec every_day(map()) :: [day_attrs()]
  def every_day(attrs), do: for(day <- 1..7, do: Map.put(attrs, :day_of_week, day))

  @doc "The labels `SlotGrid` lists on `date` for the booker, schedule rules only."
  @spec labels(Date.t(), pos_integer(), String.t(), String.t(), map()) :: [String.t()]
  def labels(date, duration, owner_tz, user_tz, config) do
    {:ok, starts} = SlotGrid.starts_for_date(date, duration, owner_tz, user_tz, config)
    Enum.map(starts, &TimeSlots.format_datetime_slot/1)
  end

  defp day(attrs) do
    Map.merge(%{is_available: true, ends_next_day: false, breaks: []}, attrs)
  end

  defp override(attrs) do
    Map.merge(
      %{schedule_id: @schedule_id, start_time: nil, end_time: nil, ends_next_day: false},
      attrs
    )
  end
end
