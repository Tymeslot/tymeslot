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

  A series confirms every session at once, with no step for the booker to
  confirm their email address, so a type that asks for one
  (`requires_email_verification`) cannot offer a series (`conflicts/1`). A
  type saved with both before the rule existed is not offered the series
  either (`offered?/1`): it books single sessions, verified.

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
  alias Tymeslot.BookingSeries.Check
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

  @doc "The session counts a host may set as a series' minimum and maximum."
  @spec count_bounds() :: Range.t()
  def count_bounds, do: @min_count..@max_count

  @doc "The intervals a recurring series may repeat at (every 1 to 4 days, weeks or months)."
  @spec intervals() :: Range.t()
  def intervals, do: @intervals

  @doc "Whether the type has a series configured, whatever the host's plan."
  @spec series?(MeetingTypeSchema.t()) :: boolean()
  def series?(%{series_mode: nil}), do: false
  def series?(%{series_mode: _mode}), do: true

  @doc """
  Whether bookers are offered the series right now: it is configured and the
  host's plan includes it. A checker failure counts as not offered, and so
  does a type that asks bookers to confirm their email, which a series would
  skip: its single sessions are verified instead. A paid group type, which
  `conflicts/1` refuses a series but which may have been saved with one
  before that rule, books single sessions too: a seat is paid per session.
  """
  @spec offered?(MeetingTypeSchema.t()) :: boolean()
  def offered?(%{series_mode: nil}), do: false
  def offered?(%{requires_email_verification: true}), do: false

  def offered?(%{payment_required: true, max_participants: max_participants})
      when is_integer(max_participants) and max_participants > 1,
      do: false

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
  def single_allowed?(meeting_type), do: offer(meeting_type).single_allowed?

  @doc """
  `offered?/1` and `single_allowed?/1` together, for a caller that needs both
  (the booking page): the plan is checked once.
  """
  @spec offer(MeetingTypeSchema.t()) :: %{offered?: boolean(), single_allowed?: boolean()}
  def offer(meeting_type) do
    offered = offered?(meeting_type)
    %{offered?: offered, single_allowed?: not offered or meeting_type.series_required == false}
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
  `:invitation_only`, `:fixed_dates`, `:requires_email_verification`,
  `:payment_required` and `:max_participants`) that cannot go with a series, as
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
       )},
      {:requires_email_verification, settings[:requires_email_verification] == true,
       dgettext_noop(
         "errors",
         "Meeting types that ask invitees to confirm their email cannot be booked as a series."
       )},
      {:payment_required,
       settings[:payment_required] == true and is_integer(settings[:max_participants]) and
         settings[:max_participants] > 1,
       dgettext_noop("errors", "Paid group meeting types cannot be booked as a series.")}
    ]
    |> Enum.filter(fn {_field, conflict?, _message} -> conflict? end)
    |> Enum.map(fn {field, _conflict?, message} -> {field, message} end)
  end

  @typedoc "A booking limit one series can exceed: the period, the limit and what a series needs."
  @type limit_conflict :: {:per_week | :per_month, pos_integer(), pos_integer()}

  # The longest week and month a booking limit counts over, in days.
  @period_days [per_week: 7, per_month: 31]
  @frequency_days %{daily: 1, weekly: 7}

  @doc """
  The booking limits (`max_bookings_per_week`, `max_bookings_per_month`) lower
  than the sessions one series can put in that period, as
  `{period, limit, needed}`, so the host can be told some series will not fit.

  Only a recurring daily or weekly series has a known number of sessions per
  week or month: a flexible one is spread by the booker, and a monthly one
  never puts more than one session in a month. The number needed is the
  sessions that fit in the longest such period (7 days, 31 days), capped at
  the series' maximum count.
  """
  @spec limit_conflicts(map()) :: [limit_conflict()]
  def limit_conflicts(
        %{
          series_mode: :recurring,
          series_frequency: frequency,
          series_interval: interval,
          series_max_occurrences: max
        } = meeting_type
      )
      when is_map_key(@frequency_days, frequency) and is_integer(interval) and interval > 0 and
             is_integer(max) do
    step = Map.fetch!(@frequency_days, frequency) * interval

    Enum.flat_map(@period_days, fn {period, days} ->
      needed = min(max, div(days - 1, step) + 1)

      case Map.get(meeting_type, limit_field(period)) do
        limit when is_integer(limit) and limit < needed -> [{period, limit, needed}]
        _no_conflict -> []
      end
    end)
  end

  def limit_conflicts(_meeting_type), do: []

  defp limit_field(:per_week), do: :max_bookings_per_week
  defp limit_field(:per_month), do: :max_bookings_per_month

  @modes %{"recurring" => :recurring, "flexible" => :flexible}
  @frequencies %{"daily" => :daily, "weekly" => :weekly, "monthly" => :monthly}

  @doc """
  The series attributes in posted form params (`series_mode`,
  `series_frequency`, `series_interval`, `series_min_occurrences`,
  `series_max_occurrences`, `series_required`). Empty when the params carry no
  `series_mode`, so a form without the series controls leaves the stored
  series alone. A blank or unknown mode is no series; a number that does not
  parse is nil, which the changeset then refuses.
  """
  @spec form_attrs(map()) :: map()
  def form_attrs(%{"series_mode" => mode} = params) do
    %{
      series_mode: Map.get(@modes, mode),
      series_frequency: Map.get(@frequencies, params["series_frequency"]),
      series_interval: parse_count(params["series_interval"]),
      series_min_occurrences: parse_count(params["series_min_occurrences"]),
      series_max_occurrences: parse_count(params["series_max_occurrences"]),
      series_required: params["series_required"] != "false"
    }
  end

  def form_attrs(_params), do: %{}

  @doc "A whole number posted by the series form, or nil when it is none."
  @spec parse_count(term()) :: integer() | nil
  def parse_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} -> count
      _invalid -> nil
    end
  end

  def parse_count(value) when is_integer(value), do: value
  def parse_count(_value), do: nil

  @doc "Validates a meeting type changeset against every series rule."
  @spec validate_changeset(Changeset.t()) :: Changeset.t()
  def validate_changeset(changeset) do
    case get_field(changeset, :series_mode) do
      nil ->
        reset_series(changeset)

      mode ->
        changeset
        |> validate_counts()
        |> validate_rhythm(mode)
        |> validate_span(mode)
        |> validate_conflicts()
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

  # Every later session must start within `Check.span_days/0` (365) of the
  # first, so a recurring rhythm caps how many sessions a series can hold. A
  # count is refused when it fails for any first date, since a fixed package
  # at that count could not be booked from those dates at all. Daily and
  # weekly steps are whole days in the host's wall-clock time, so the cap is
  # exact; a clock change moves a start by an hour at most, and no weekly cap
  # lands within an hour of the span (every 4 weeks, 14 sessions: 364 days).
  # Monthly steps keep the weekday ordinal, so their length in days varies:
  # eleven months always fit (at most 343 days), twelve span 364 to 371
  # depending on the first date, so a series may step at most eleven months
  # past its first session.
  @span_months 11

  defp validate_span(changeset, :recurring) do
    frequency = get_field(changeset, :series_frequency)
    interval = get_field(changeset, :series_interval)

    case max_fitting_count(frequency, interval) do
      nil ->
        changeset

      fitting ->
        min = get_field(changeset, :series_min_occurrences)
        max = get_field(changeset, :series_max_occurrences)

        changeset
        |> check_fits(:series_max_occurrences, max, fitting)
        # Equal bounds show as one field, so the error is not repeated there.
        |> check_fits(:series_min_occurrences, if(min != max, do: min), fitting)
    end
  end

  defp validate_span(changeset, :flexible), do: changeset

  @doc """
  The most sessions a recurring series at `frequency` every `interval` can
  hold with every one inside `Tymeslot.BookingSeries.Check.span_days/0` of
  the first, whatever the first date, or nil for a rhythm that is not valid.
  """
  @spec max_fitting_count(atom(), term()) :: pos_integer() | nil
  def max_fitting_count(:monthly, interval) when interval in @intervals,
    do: div(@span_months, interval) + 1

  def max_fitting_count(frequency, interval)
      when is_map_key(@frequency_days, frequency) and interval in @intervals,
      do: div(Check.span_days(), Map.fetch!(@frequency_days, frequency) * interval) + 1

  def max_fitting_count(_frequency, _interval), do: nil

  defp check_fits(changeset, field, count, fitting) when is_integer(count) and count > fitting do
    add_error(
      changeset,
      field,
      dgettext_noop(
        "errors",
        "must be at most %{max} at this rhythm, so that every session falls within a year"
      ),
      max: fitting
    )
  end

  defp check_fits(changeset, _field, _count, _fitting), do: changeset

  @doc """
  Adds an error for every setting that cannot go with the series mode, read
  with `get_field/2`. For the narrow changesets that can set `one_off`,
  `invitation_only` or `fixed_dates` without running `validate_changeset/1`.
  The error sits on `:series_mode` when the change turns the series on or
  changes its mode, and otherwise on the conflicting setting.
  """
  @spec validate_conflicts(Changeset.t()) :: Changeset.t()
  def validate_conflicts(changeset) do
    settings = %{
      series_mode: get_field(changeset, :series_mode),
      one_off: get_field(changeset, :one_off),
      invitation_only: get_field(changeset, :invitation_only),
      fixed_dates: get_field(changeset, :fixed_dates),
      requires_email_verification: get_field(changeset, :requires_email_verification),
      payment_required: get_field(changeset, :payment_required),
      max_participants: get_field(changeset, :max_participants)
    }

    series_changed? = fetch_change(changeset, :series_mode) != :error

    Enum.reduce(conflicts(settings), changeset, fn {culprit, message}, acc ->
      add_error(acc, if(series_changed?, do: :series_mode, else: culprit), message)
    end)
  end
end
