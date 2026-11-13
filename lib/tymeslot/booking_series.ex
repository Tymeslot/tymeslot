defmodule Tymeslot.BookingSeries do
  @moduledoc """
  Booking a series: several sessions of one meeting type in a single flow,
  each becoming an ordinary booking.

  `preview/3` answers, before anything is written, which of the sessions a
  booker asks for can be booked (`Tymeslot.BookingSeries.Check`). The series
  is all-or-nothing: it is booked only when every occurrence is available.
  `book/3` books it (`Tymeslot.BookingSeries.Create`). `describe_rule/3`
  words a series' rhythm for anyone who shows it
  (`Tymeslot.BookingSeries.Rule`).
  """

  alias Tymeslot.Availability.Schedules

  alias Tymeslot.BookingSeries.{
    Check,
    Create,
    Occurrence,
    Plan,
    Rule,
    SeriesQueries,
    SeriesSchema
  }

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @doc """
  Plans the series and judges each occurrence.

  Given a `DateTime`, the series is recurring from that first start and
  `opts[:count]` sets how many sessions it has, and the type must be a
  recurring series type; given a list of starts, it is the flexible series
  of those sessions.

  Options: `:count` (recurring only), `:booker_tz` and `:duration_minutes`
  (see `Plan.recurring/4`), and `:now`, `:booker_email` and `:guests` (see
  `Check.check/2`).
  """
  @spec preview(MeetingTypeSchema.t(), DateTime.t() | [DateTime.t()], keyword()) ::
          {:ok, [Occurrence.t()]}
          | {:error, :invalid_count | :overlapping_starts | :availability_unverifiable}
  def preview(meeting_type, first_or_starts, opts \\ []) do
    opts =
      Keyword.put_new_lazy(opts, :config, fn ->
        Schedules.booking_config(meeting_type.user_id, meeting_type)
      end)

    with {:ok, plan} <- plan(meeting_type, first_or_starts, opts) do
      Check.check(plan, opts)
    end
  end

  @doc """
  Books the series `meeting_params.series` asks for, every session an
  ordinary meeting (or, on a group type, a seat in one), all or none.
  Returns the series, its meetings and the booker's seats in them; see
  `Tymeslot.BookingSeries.Create.execute/3`.
  """
  @spec book(map(), map(), keyword()) :: Create.result()
  defdelegate book(meeting_params, form_data, opts \\ []), to: Create, as: :execute

  @doc """
  The meetings of a one-to-one series, in series order. Unscoped: for
  system callers that already hold the series.
  """
  @spec meetings(SeriesSchema.t() | binary()) :: [MeetingSchema.t()]
  def meetings(series_or_id), do: SeriesQueries.list_meetings(series_or_id)

  @doc """
  How many sessions the series a meeting belongs to has, or nil for a
  meeting outside any series (or whose series is gone).
  """
  @spec session_count(MeetingSchema.t()) :: pos_integer() | nil
  def session_count(%MeetingSchema{series_id: nil}), do: nil

  def session_count(%MeetingSchema{series_id: series_id}) do
    case SeriesQueries.get(series_id) do
      {:ok, %SeriesSchema{occurrences_count: count}} -> count
      {:error, :not_found} -> nil
    end
  end

  @doc """
  How the rhythm of a series or a series type reads in `locale`: "Every
  week on Thursday at 17:00" with the `:first_start` option (in the zone it
  is to be read in), "Every week" without. Nil for a flexible series or a
  type that offers no recurring series. See `Tymeslot.BookingSeries.Rule`.
  """
  @spec describe_rule(SeriesSchema.t() | MeetingTypeSchema.t(), String.t(), keyword()) ::
          String.t() | nil
  defdelegate describe_rule(series_or_type, locale, opts \\ []), to: Rule, as: :describe

  defp plan(meeting_type, %DateTime{} = first_start, opts),
    do: Plan.recurring(meeting_type, first_start, Keyword.get(opts, :count), opts)

  defp plan(meeting_type, starts, opts) when is_list(starts),
    do: Plan.flexible(meeting_type, starts, opts)
end
