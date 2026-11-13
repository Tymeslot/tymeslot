defmodule Tymeslot.MeetingTypes.SeriesSettings do
  @moduledoc """
  The series rules of a meeting type, kept apart from
  `Tymeslot.MeetingTypes.MeetingTypeSchema` like the group and payment rules.

  A series lets a booker book several sessions in one flow. A type has one of
  two modes (`series_mode`; nil means no series):

    * `:recurring`: the same time on a fixed rhythm the host sets
      (`series_frequency` every `series_interval` days, weeks or months);
    * `:flexible`: the booker picks the sessions at any offered times.

  Either way the booker books between `series_min_occurrences` and
  `series_max_occurrences` sessions; equal bounds make a fixed package.
  `series_required: false` also lets a booker book a single session.

  Offering a series is a Pro feature on the managed plan
  (`:recurring_bookings_allowed`), checked when it is switched on
  (`Tymeslot.MeetingTypes.FormValidation`) and again when a booker books
  (`offered?/1`), so a host who loses Pro keeps the series they set up but
  their type books single sessions.

  The messages are msgids of the `errors` domain, registered with
  `dgettext_noop/2` and translated where the form shows them.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset,
    only: [
      add_error: 3,
      add_error: 4,
      fetch_change: 2,
      get_field: 2,
      put_change: 3,
      validate_required: 2
    ]

  alias Ecto.Changeset
  alias Tymeslot.Features
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  require Logger

  @min_count 2
  @max_count 26
  @intervals 1..4

  @feature :recurring_bookings_allowed

  @doc "The feature atom the Pro gate checks."
  @spec feature() :: atom()
  def feature, do: @feature

  @doc "Whether the type has a series configured, whatever the host's plan."
  @spec series?(MeetingTypeSchema.t()) :: boolean()
  def series?(%{series_mode: nil}), do: false
  def series?(%{series_mode: _mode}), do: true

  @doc """
  Whether bookers are offered the series right now: it is configured and the
  host's plan includes it. A checker failure counts as not offered.
  """
  @spec offered?(MeetingTypeSchema.t()) :: boolean()
  def offered?(%{series_mode: nil}), do: false

  def offered?(%{user_id: user_id}) do
    case Features.check_access(user_id, @feature) do
      :ok ->
        true

      {:error, :feature_access_checker_failed} ->
        Logger.warning("Recurring bookings access check failed; offering single sessions",
          user_id: user_id
        )

        false

      {:error, _denied} ->
        false
    end
  end

  @doc "Whether a booker may book one session instead of a series."
  @spec single_allowed?(MeetingTypeSchema.t()) :: boolean()
  def single_allowed?(meeting_type) do
    not offered?(meeting_type) or meeting_type.series_required == false
  end

  @doc """
  The session counts a booker may choose. Only for a type with a series mode;
  a type without one raises `FunctionClauseError`.
  """
  @spec count_range(MeetingTypeSchema.t()) :: Range.t()
  def count_range(%{
        series_mode: mode,
        series_min_occurrences: min,
        series_max_occurrences: max
      })
      when mode != nil,
      do: min..max

  @doc """
  The settings of a type (a map with `:series_mode`, `:one_off`,
  `:invitation_only` and `:fixed_dates`) that cannot go with a series, as
  `{culprit_field, message}`. The culprit is the field that, were it not set,
  would lift the conflict. Empty when there is no series.
  """
  @spec conflicts(map()) :: [{atom(), String.t()}]
  def conflicts(%{series_mode: nil}), do: []

  def conflicts(settings) do
    [
      {:one_off, settings[:one_off] == true,
       dgettext_noop("errors", "One-off meeting types cannot be booked as a series.")},
      {:invitation_only, settings[:invitation_only] == true,
       dgettext_noop("errors", "Invitation-only meeting types cannot be booked as a series.")},
      {:fixed_dates, settings[:series_mode] == :recurring and settings[:fixed_dates] == true,
       dgettext_noop(
         "errors",
         "Meeting types with fixed dates can offer a series only as sessions the booker picks."
       )}
    ]
    |> Enum.filter(fn {_field, conflict?, _message} -> conflict? end)
    |> Enum.map(fn {field, _conflict?, message} -> {field, message} end)
  end

  @doc "Validates a meeting type changeset against every series rule."
  @spec validate_changeset(Changeset.t()) :: Changeset.t()
  def validate_changeset(changeset) do
    case get_field(changeset, :series_mode) do
      nil -> reset_series(changeset)
      mode -> changeset |> validate_counts() |> validate_rhythm(mode) |> validate_conflicts()
    end
  end

  # With no series mode every other series field sits at its default, whether
  # the series was just switched off or never on.
  defp reset_series(changeset) do
    changeset
    |> put_change(:series_frequency, nil)
    |> put_change(:series_interval, 1)
    |> put_change(:series_min_occurrences, nil)
    |> put_change(:series_max_occurrences, nil)
    |> put_change(:series_required, true)
  end

  defp validate_counts(changeset) do
    changeset = validate_required(changeset, [:series_min_occurrences, :series_max_occurrences])
    min = get_field(changeset, :series_min_occurrences)
    max = get_field(changeset, :series_max_occurrences)

    changeset
    |> check_count(:series_min_occurrences, min, @min_count, @max_count)
    |> check_count(:series_max_occurrences, max, @min_count, @max_count)
    |> check_order(min, max)
  end

  defp check_count(changeset, field, value, low, high)
       when is_integer(value) and (value < low or value > high) do
    add_error(changeset, field, dgettext_noop("errors", "must be between %{min} and %{max}"),
      min: low,
      max: high
    )
  end

  defp check_count(changeset, _field, _value, _low, _high), do: changeset

  defp check_order(changeset, min, max) when is_integer(min) and is_integer(max) and max < min do
    add_error(
      changeset,
      :series_max_occurrences,
      dgettext_noop("errors", "must not be less than the minimum")
    )
  end

  defp check_order(changeset, _min, _max), do: changeset

  defp validate_rhythm(changeset, :recurring) do
    changeset = validate_required(changeset, [:series_frequency])
    interval = get_field(changeset, :series_interval)

    if is_integer(interval) and interval in @intervals do
      changeset
    else
      add_error(
        changeset,
        :series_interval,
        dgettext_noop("errors", "must be between %{min} and %{max}"),
        min: @intervals.first,
        max: @intervals.last
      )
    end
  end

  defp validate_rhythm(changeset, :flexible) do
    changeset
    |> put_change(:series_frequency, nil)
    |> put_change(:series_interval, 1)
  end

  @doc """
  Adds an error for every setting that cannot go with the series mode, read
  with `get_field/2`. For the narrow changesets that can set `one_off`,
  `invitation_only` or `fixed_dates` without running `validate_changeset/1`.
  """
  @spec validate_conflicts(Changeset.t()) :: Changeset.t()
  def validate_conflicts(changeset) do
    settings = %{
      series_mode: get_field(changeset, :series_mode),
      one_off: get_field(changeset, :one_off),
      invitation_only: get_field(changeset, :invitation_only),
      fixed_dates: get_field(changeset, :fixed_dates)
    }

    series_changed? = fetch_change(changeset, :series_mode) != :error

    Enum.reduce(conflicts(settings), changeset, fn {culprit, message}, acc ->
      add_error(acc, if(series_changed?, do: :series_mode, else: culprit), message)
    end)
  end
end
