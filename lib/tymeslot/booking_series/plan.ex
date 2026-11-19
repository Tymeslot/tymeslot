defmodule Tymeslot.BookingSeries.Plan do
  @moduledoc """
  The sessions a booker asks for, before anything is checked: the meeting
  type, the starts in ascending order, the length of each session, and the
  two timezones the checks need (the host's, which holds a recurring series'
  wall-clock time, and the booker's, which decides the date a start is
  offered under).

  `recurring/4` expands the starts from the first through
  `Tymeslot.BookingSeries.Dates`; `flexible/3` takes the starts the booker
  picked. Both refuse a session count outside the type's
  (`SeriesSettings.count_range/1`). Neither checks availability:
  `Tymeslot.BookingSeries.Check` does.

  The plan carries the type's scheduling config
  (`Schedules.booking_config/2`), read once: its `owner_timezone` is the
  host's timezone, and `Check` judges every occurrence against it.
  """

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.BookingSeries.Dates
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.SeriesSettings

  @type t :: %__MODULE__{
          meeting_type: MeetingTypeSchema.t(),
          mode: :recurring | :flexible,
          starts: [DateTime.t()],
          duration_minutes: pos_integer(),
          organizer_user_id: pos_integer(),
          host_tz: String.t(),
          booker_tz: String.t(),
          config: map()
        }

  @enforce_keys [
    :meeting_type,
    :mode,
    :starts,
    :duration_minutes,
    :organizer_user_id,
    :host_tz,
    :booker_tz,
    :config
  ]
  defstruct @enforce_keys

  @doc """
  A recurring series of `count` sessions from `first_start`, on the type's
  rhythm (`series_frequency` every `series_interval`). The type must be a
  recurring series type (`series_mode: :recurring`); any other raises.

  Options:

    * `:booker_tz` - the booker's timezone (default: the host's).
    * `:duration_minutes` - the length the booker chose, when the type
      offers several (default: the type's own).
    * `:config` - the type's `Schedules.booking_config/2`, when the caller
      already holds it (default: read here).
  """
  @spec recurring(MeetingTypeSchema.t(), DateTime.t(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, :invalid_count}
  def recurring(
        %MeetingTypeSchema{series_mode: :recurring} = meeting_type,
        %DateTime{} = first_start,
        count,
        opts \\ []
      ) do
    if valid_count?(meeting_type, count) do
      config = config(meeting_type, opts)

      starts =
        Dates.recurring_starts(
          DateTime.shift_zone!(first_start, "Etc/UTC"),
          meeting_type.series_frequency,
          meeting_type.series_interval,
          count,
          config.owner_timezone
        )

      {:ok, build(meeting_type, :recurring, starts, config, opts)}
    else
      {:error, :invalid_count}
    end
  end

  @doc """
  A flexible series of the sessions the booker picked, in any order. Picks
  whose sessions overlap (`[start, start + duration)`) are refused: one
  booking cannot hold the host twice at once.

  Takes the same options as `recurring/4`.
  """
  @spec flexible(MeetingTypeSchema.t(), [DateTime.t()], keyword()) ::
          {:ok, t()} | {:error, :invalid_count | :overlapping_starts}
  def flexible(%MeetingTypeSchema{} = meeting_type, starts, opts \\ []) when is_list(starts) do
    starts = starts |> Enum.map(&DateTime.shift_zone!(&1, "Etc/UTC")) |> Enum.sort(DateTime)
    duration = duration_minutes(meeting_type, opts)

    cond do
      not valid_count?(meeting_type, length(starts)) ->
        {:error, :invalid_count}

      overlapping?(starts, duration) ->
        {:error, :overlapping_starts}

      true ->
        {:ok, build(meeting_type, :flexible, starts, config(meeting_type, opts), opts)}
    end
  end

  defp build(meeting_type, mode, starts, config, opts) do
    %__MODULE__{
      meeting_type: meeting_type,
      mode: mode,
      starts: starts,
      duration_minutes: duration_minutes(meeting_type, opts),
      organizer_user_id: meeting_type.user_id,
      host_tz: config.owner_timezone,
      booker_tz: Keyword.get(opts, :booker_tz) || config.owner_timezone,
      config: config
    }
  end

  defp config(meeting_type, opts),
    do:
      Keyword.get_lazy(opts, :config, fn ->
        Schedules.booking_config(meeting_type.user_id, meeting_type)
      end)

  defp duration_minutes(meeting_type, opts),
    do: Offer.duration_minutes(meeting_type, nil, Keyword.get(opts, :duration_minutes))

  # The starts are sorted, so only neighbours can overlap.
  defp overlapping?(starts, duration) do
    starts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [earlier, later] ->
      DateTime.compare(later, DateTime.add(earlier, duration, :minute)) == :lt
    end)
  end

  defp valid_count?(meeting_type, count),
    do: is_integer(count) and count in SeriesSettings.count_range(meeting_type)
end
