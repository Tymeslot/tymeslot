defmodule Tymeslot.BookingSeries do
  @moduledoc """
  Booking a series: several sessions of one meeting type in a single flow,
  each becoming an ordinary booking.

  `preview/3` answers, before anything is written, which of the sessions a
  booker asks for can be booked (`Tymeslot.BookingSeries.Check`). The series
  is all-or-nothing: it is booked only when every occurrence is available.
  `book/3` books it (`Tymeslot.BookingSeries.Create`). `describe_rule/3`
  words a series' rhythm for anyone who shows it
  (`Tymeslot.BookingSeries.Rule`). `cancel_remaining/2` calls off every
  session still to come (`Tymeslot.BookingSeries.Cancel`).
  """

  alias Tymeslot.Availability.Schedules

  alias Tymeslot.BookingSeries.{
    Approval,
    Cancel,
    Check,
    Create,
    Occurrence,
    Plan,
    Rule,
    SeriesQueries,
    SeriesSchema,
    Sessions
  }

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo

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
  Cancels every session of `series` still to come, with one email to each
  side and, for a host cancelling a paid series, one refund job scheduled
  with the cancellation (`refund: {:scheduled, cents}`), or the reason the
  default refund could not be made (`{:not_refunded, reason}`). Options
  `:caller` (required), `:acting_user` and `:refund`; see
  `Tymeslot.BookingSeries.Cancel.cancel_remaining/2`.
  """
  @spec cancel_remaining(SeriesSchema.t(), keyword()) :: Cancel.result()
  defdelegate cancel_remaining(series, opts), to: Cancel

  @doc """
  Closes a series once nothing of it is left to come, after one of its
  sessions was cancelled on its own. See
  `Tymeslot.BookingSeries.Cancel.maybe_close/1`.
  """
  @spec maybe_close(SeriesSchema.t() | binary()) :: :ok
  defdelegate maybe_close(series_or_id), to: Cancel

  @doc """
  The series behind the attendee's series link, by its bearer `uid`;
  `{:error, :not_found}` for an unknown or malformed one.
  """
  @spec get_for_attendee(term()) :: {:ok, SeriesSchema.t()} | {:error, :not_found}
  def get_for_attendee(uid) when is_binary(uid), do: SeriesQueries.get_by_uid(uid)
  def get_for_attendee(_uid), do: {:error, :not_found}

  @doc """
  The attendee's series page: every session with its status and links,
  how many "Cancel all remaining" would cancel, and whether the series is
  an open request or was paid for. See `Tymeslot.BookingSeries.Sessions`.
  """
  @spec attendee_overview(SeriesSchema.t(), map() | nil) :: Sessions.overview()
  def attendee_overview(%SeriesSchema{} = series, organizer_profile),
    do: Sessions.for_attendee(series, organizer_profile)

  @doc """
  The host's dashboard view of a series they organise: every session with
  its meeting and status, how many "Cancel remaining sessions" cancels,
  whether it is an open request, its payment and the default refund for
  cancelling the rest. See `Tymeslot.BookingSeries.Sessions.for_organizer/2`.
  Take `series` from `get_for_organizer/2`, which checks the host owns it.
  """
  @spec organizer_overview(SeriesSchema.t()) :: Sessions.organizer_overview()
  def organizer_overview(%SeriesSchema{} = series), do: Sessions.for_organizer(series)

  @doc """
  The `:refund` option for `cancel_remaining/2` that the host's choice in
  the cancellation form implies. See `Cancel.resolve_refund_choice/2`.
  """
  @spec resolve_refund_choice(map() | nil, map()) ::
          {:ok, Cancel.refund_choice()}
          | {:error, :acknowledgement_required | :exceeds_remaining | :invalid_amount}
  defdelegate resolve_refund_choice(payment, params), to: Cancel

  @doc """
  Where a listed meeting sits in its series, `{position, count}`, read from
  its preloaded series; nil for a meeting outside any series, or whose
  series was not loaded.
  """
  @spec place(MeetingSchema.t()) :: {pos_integer(), pos_integer()} | nil
  def place(%MeetingSchema{
        series_position: position,
        series: %SeriesSchema{occurrences_count: count}
      })
      when is_integer(position),
      do: {position, count}

  def place(_meeting), do: nil

  @doc """
  `meeting` with its series and that series' meetings, in series order,
  loaded, for `request_sessions/1`. A meeting outside any series is
  returned as it is.
  """
  @spec with_request_sessions(MeetingSchema.t()) :: MeetingSchema.t()
  def with_request_sessions(%MeetingSchema{series_id: nil} = meeting), do: meeting

  def with_request_sessions(%MeetingSchema{} = meeting) do
    %MeetingSchema{} =
      loaded =
      Repo.preload(meeting, [series: [meetings: SeriesQueries.ordered_meetings()]], force: true)

    loaded
  end

  @doc """
  The sessions of the open series request `meeting` belongs to, in series
  order, read from the series sessions loaded on it (the meetings list
  loads them for requests, `with_request_sessions/1` for one meeting); nil
  when it is no part of one, or they are not loaded. Approving or declining
  any of them answers them all (`Tymeslot.BookingSeries.Approval`).
  """
  @spec request_sessions(MeetingSchema.t()) :: [MeetingSchema.t()] | nil
  def request_sessions(%MeetingSchema{series: %SeriesSchema{meetings: sessions}} = meeting)
      when is_list(sessions),
      do: Approval.request_sessions(meeting, sessions)

  def request_sessions(_meeting), do: nil

  @doc """
  The sessions of the series request `meeting` was part of, whatever has
  become of it since (open, approved, declined or expired), read from the
  series sessions loaded on it (`with_request_sessions/1`): every session of
  its series requested with it, at the same `approval_requested_at`, in
  series order. Nil for a meeting requested on its own, outside any series,
  or whose series sessions are not loaded.
  """
  @spec sessions_requested_with(MeetingSchema.t()) :: [MeetingSchema.t()] | nil
  def sessions_requested_with(%MeetingSchema{
        id: id,
        approval_requested_at: %DateTime{} = requested_at,
        series: %SeriesSchema{meetings: sessions}
      })
      when is_list(sessions) do
    case Enum.filter(sessions, &(&1.approval_requested_at == requested_at)) do
      [_alone] -> nil
      together -> if Enum.any?(together, &(&1.id == id)), do: together
    end
  end

  def sessions_requested_with(_meeting), do: nil

  @doc """
  The series `series_id` when `user_id` is its organiser, else
  `{:error, :not_found}`, as for an unknown or malformed id.
  """
  @spec get_for_organizer(term(), integer()) :: {:ok, SeriesSchema.t()} | {:error, :not_found}
  def get_for_organizer(series_id, user_id) when is_binary(series_id) and is_integer(user_id),
    do: SeriesQueries.get_for_organizer(series_id, user_id)

  def get_for_organizer(_series_id, _user_id), do: {:error, :not_found}

  @doc """
  The occurrences of a series in series order: its meetings on a one-to-one
  type, its seats (each with its meeting) on a group type.
  """
  @spec occurrences(SeriesSchema.t()) :: [MeetingSchema.t() | ParticipantSchema.t()]
  def occurrences(%SeriesSchema{} = series), do: SeriesQueries.list_occurrences(series)

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

  @doc """
  How the rhythm of `series` reads as its sessions now stand, each of
  `starts` read in `timezone`: with its day and time while every session
  keeps them, the rhythm alone once one was moved. See
  `Tymeslot.BookingSeries.Rule.describe_sessions/5`.
  """
  @spec describe_rule_for_sessions(
          SeriesSchema.t(),
          [DateTime.t()],
          String.t(),
          String.t(),
          keyword()
        ) :: String.t() | nil
  defdelegate describe_rule_for_sessions(series, starts, locale, timezone, opts \\ []),
    to: Rule,
    as: :describe_sessions

  @typedoc "A meeting or a seat, read for the series it belongs to."
  @type occurrence :: %{:series_id => binary() | nil, optional(atom()) => any()}

  @doc """
  The last day a later session of the series `occurrence` (a meeting or a
  seat) belongs to may be moved to: a year after the series' first session
  as booked, the span every session was booked within. The anchor does not
  move with the sessions, so moving them cannot push the limit later. The
  booking window binds the first session alone, so a later one can lie past
  it and still be moved; the first session itself keeps the window, and gets
  nil, as does an occurrence outside a series.
  """
  @spec window_until(occurrence()) :: Date.t() | nil
  def window_until(%{series_id: nil}), do: nil
  def window_until(%{series_position: 1}), do: nil

  def window_until(%{series_id: series_id}) when is_binary(series_id) do
    case SeriesQueries.first_start(series_id) do
      %DateTime{} = first -> first |> DateTime.add(Check.span_days(), :day) |> DateTime.to_date()
      nil -> nil
    end
  end

  @doc """
  `config`'s booking window (`:max_advance_booking_days`) widened, for
  moving a session of a series, to reach `window_until/1` from today. A
  window already reaching further, and one outside a series, is kept.
  The notice is untouched.
  """
  @spec widen_window(map(), occurrence()) :: map()
  def widen_window(config, occurrence) do
    case window_until(occurrence) do
      nil -> config
      until -> reach_until(config, until)
    end
  end

  @doc """
  `config`'s booking window widened to reach `until` from today, as a
  series' later sessions are offered and moved.
  """
  @spec reach_until(map(), Date.t()) :: map()
  def reach_until(config, %Date{} = until) do
    days = reach_days(0, until)
    Map.update(config, :max_advance_booking_days, days, &reach_days(&1, until))
  end

  @doc """
  A booking window of `days` widened to reach `until` from today; `days`
  itself when it already does, or when there is no `until`.
  """
  @spec reach_days(non_neg_integer(), Date.t() | nil) :: non_neg_integer()
  def reach_days(days, nil), do: days
  def reach_days(days, %Date{} = until), do: max(days, Date.diff(until, Clock.utc_today()) + 1)

  @doc """
  What a series of `count` sessions of `meeting_type` costs, in cents: the
  type's price for each session, as its checkout bills it (one line at the
  unit price, the session count as its quantity). Nil for a type that takes
  no payment.
  """
  @spec total_cents(map(), pos_integer()) :: pos_integer() | nil
  def total_cents(%{payment_required: true, price_cents: cents}, count)
      when is_integer(cents) and cents > 0 and is_integer(count) and count > 0,
      do: cents * count

  def total_cents(_meeting_type, _count), do: nil

  defp plan(meeting_type, %DateTime{} = first_start, opts),
    do: Plan.recurring(meeting_type, first_start, Keyword.get(opts, :count), opts)

  defp plan(meeting_type, starts, opts) when is_list(starts),
    do: Plan.flexible(meeting_type, starts, opts)
end
