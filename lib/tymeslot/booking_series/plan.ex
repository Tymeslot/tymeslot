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
  """

  alias Tymeslot.Availability.Offer
  alias Tymeslot.BookingSeries.Dates
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.SeriesSettings
  alias Tymeslot.Profiles

  @type t :: %__MODULE__{
          meeting_type: MeetingTypeSchema.t(),
          mode: :recurring | :flexible,
          starts: [DateTime.t()],
          duration_minutes: pos_integer(),
          organizer_user_id: pos_integer(),
          host_tz: String.t(),
          booker_tz: String.t()
        }

  @enforce_keys [
    :meeting_type,
    :mode,
    :starts,
    :duration_minutes,
    :organizer_user_id,
    :host_tz,
    :booker_tz
  ]
  defstruct @enforce_keys

  @doc """
  A recurring series of `count` sessions from `first_start`, on the type's
  rhythm (`series_frequency` every `series_interval`).

  Options:

    * `:booker_tz` - the booker's timezone (default: the host's).
    * `:duration_minutes` - the length the booker chose, when the type
      offers several (default: the type's own).
  """
  @spec recurring(MeetingTypeSchema.t(), DateTime.t(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, :invalid_count}
  def recurring(%MeetingTypeSchema{} = meeting_type, %DateTime{} = first_start, count, opts \\ []) do
    if valid_count?(meeting_type, count) do
      host_tz = host_timezone(meeting_type)

      starts =
        Dates.recurring_starts(
          DateTime.shift_zone!(first_start, "Etc/UTC"),
          meeting_type.series_frequency,
          meeting_type.series_interval,
          count,
          host_tz
        )

      {:ok, build(meeting_type, :recurring, starts, host_tz, opts)}
    else
      {:error, :invalid_count}
    end
  end

  @doc """
  A flexible series of the sessions the booker picked, in any order. Two
  picks at the same instant are refused.

  Takes the same options as `recurring/4`.
  """
  @spec flexible(MeetingTypeSchema.t(), [DateTime.t()], keyword()) ::
          {:ok, t()} | {:error, :invalid_count | :duplicate_start}
  def flexible(%MeetingTypeSchema{} = meeting_type, starts, opts \\ []) when is_list(starts) do
    starts = starts |> Enum.map(&DateTime.shift_zone!(&1, "Etc/UTC")) |> Enum.sort(DateTime)

    cond do
      not valid_count?(meeting_type, length(starts)) ->
        {:error, :invalid_count}

      length(Enum.dedup_by(starts, &DateTime.to_unix(&1, :microsecond))) != length(starts) ->
        {:error, :duplicate_start}

      true ->
        {:ok, build(meeting_type, :flexible, starts, host_timezone(meeting_type), opts)}
    end
  end

  defp build(meeting_type, mode, starts, host_tz, opts) do
    %__MODULE__{
      meeting_type: meeting_type,
      mode: mode,
      starts: starts,
      duration_minutes:
        Offer.duration_minutes(meeting_type, nil, Keyword.get(opts, :duration_minutes)),
      organizer_user_id: meeting_type.user_id,
      host_tz: host_tz,
      booker_tz: Keyword.get(opts, :booker_tz) || host_tz
    }
  end

  defp valid_count?(meeting_type, count),
    do: is_integer(count) and count in SeriesSettings.count_range(meeting_type)

  # The zone `Schedules.booking_config/2` reads the host's schedule in, with
  # the same fallback for a profile without one.
  defp host_timezone(%{user_id: user_id}), do: Profiles.get_profile_settings(user_id).timezone
end
