defmodule Tymeslot.Test.MidnightRewrite do
  @moduledoc """
  The 23:59-to-midnight rewrite, applied to an in-memory schedule built by
  `Tymeslot.Test.SlotGridHelpers.pure_config/1`, so a slot-engine property can
  state what the rewrite changes for bookers. The migration test is the
  authority on the SQL itself; this mirrors its rule and nothing more.
  """

  @end_of_day ~T[23:59:00]
  @midnight ~T[00:00:00]

  @spec apply(map()) :: map()
  def apply(config) do
    %{
      config
      | weekly_schedule: Enum.map(config.weekly_schedule, &rewrite_day/1),
        overrides: Enum.map(config.overrides, &rewrite_hours/1)
    }
  end

  @doc "Whether the rewrite changes this weekly row or override."
  @spec rewritten?(map()) :: boolean()
  def rewritten?(%{start_time: %Time{} = start_time, end_time: %Time{} = end_time} = row) do
    not Map.get(row, :ends_next_day, false) and Time.compare(end_time, @end_of_day) != :lt and
      Time.compare(start_time, end_time) == :lt
  end

  def rewritten?(_row), do: false

  defp rewrite_day(day) do
    if rewritten?(day) do
      breaks =
        Enum.map(
          day.breaks,
          &if(Time.compare(&1.end_time, @end_of_day) != :lt,
            do: %{&1 | end_time: @midnight},
            else: &1
          )
        )

      %{day | end_time: @midnight, ends_next_day: true, breaks: breaks}
    else
      day
    end
  end

  defp rewrite_hours(override) do
    if rewritten?(override),
      do: %{override | end_time: @midnight, ends_next_day: true},
      else: override
  end
end
