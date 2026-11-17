defmodule Tymeslot.BookingSeries.Sessions do
  @moduledoc """
  Where each session of a series stands, as its booker sees it on the
  series page (`/:username/series/:series_uid`): every session in series
  order with its status and, for one still to come, its own reschedule and
  cancel links; how many sessions "Cancel all remaining" would call off;
  whether the series is still an open approval request; and whether a
  payment was taken for it.

  A session is one of:

    * `:upcoming` - live and still to start, with the booker's own
      reschedule and cancel links: the meeting's on a one-to-one series,
      their seat's on a group one;
    * `:past` - started or over;
    * `:cancelled` - cancelled, a request that lapsed, or a seat given up;
    * `:awaiting_approval` - held for the host's decision. Within an open
      series request it has no links, as the request is withdrawn whole;
      held on its own (moved back into the gate by a reschedule) it has
      its own cancel link;
    * `:awaiting_payment` - held for the series' checkout, no links.

  `upcoming` counts the sessions "Cancel all remaining" cancels, by the
  rule `Tymeslot.BookingSeries.Cancel` itself applies
  (`Cancel.cancellable?/2`), so the page never promises a different
  number; `open_request` is `Cancel.open_request?/1`, the same test that
  decides whether the call withdraws the request instead.

  `for_organizer/2` is the host's view of the same sessions on their
  dashboard: each with its meeting and status but no booker's links, with
  the series' payment and the refund cancelling the rest makes by default.
  """

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.BookingSeries.Cancel
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Clock
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Repo

  @type status :: :upcoming | :past | :cancelled | :awaiting_approval | :awaiting_payment

  @type links :: %{reschedule_url: String.t() | nil, cancel_url: String.t() | nil}

  @type session :: %{
          position: pos_integer(),
          meeting: Meeting.t(),
          start_time: DateTime.t(),
          status: status(),
          links: links() | nil
        }

  @type overview :: %{
          series: SeriesSchema.t(),
          sessions: [session()],
          upcoming: non_neg_integer(),
          held_for_approval: non_neg_integer(),
          open_request: boolean(),
          paid: boolean()
        }

  # A payment that took money the booker may want back.
  @paid_statuses [:paid, :partially_refunded]

  @doc """
  The series page's view of `series` (see the module docs), its meeting
  type preloaded. `organizer_profile` (the organiser's profile, `nil` when
  they have none) names the username the meeting links are built on.
  """
  @spec for_attendee(SeriesSchema.t(), map() | nil, DateTime.t()) :: overview()
  def for_attendee(%SeriesSchema{} = series, organizer_profile, now \\ Clock.utc_now()) do
    occurrences = SeriesQueries.list_occurrences(series)
    open_request = Cancel.open_request?(series)
    sessions = Enum.map(occurrences, &session(&1, organizer_profile, open_request, now))

    %{
      series: Repo.preload(series, :meeting_type),
      sessions: sessions,
      upcoming: Enum.count(occurrences, &Cancel.cancellable?(&1, now)),
      held_for_approval: Enum.count(sessions, &(&1.status == :awaiting_approval)),
      open_request: open_request,
      paid: paid?(series)
    }
  end

  @type organizer_session :: %{
          position: pos_integer(),
          meeting: Meeting.t(),
          start_time: DateTime.t(),
          status: status(),
          seat: boolean()
        }

  @type organizer_overview :: %{
          series: SeriesSchema.t(),
          sessions: [organizer_session()],
          upcoming: non_neg_integer(),
          open_request: boolean(),
          payment: map() | nil,
          remaining_refund_cents: non_neg_integer()
        }

  @doc """
  The host's view of `series` on their dashboard, its meeting type
  preloaded: every session in series order with its meeting, its status
  and whether it is a seat in a shared group session (`seat`), how
  many "Cancel remaining sessions" would cancel (`upcoming`, by
  `Cancel.cancellable?/2`, as for the booker), whether it is still an open
  request, the payment taken for it (nil when none was taken), and the
  refund cancelling the remaining sessions makes by default
  (`Cancel.remaining_share_cents/3`, 0 without a payment).
  """
  @spec for_organizer(SeriesSchema.t(), DateTime.t()) :: organizer_overview()
  def for_organizer(%SeriesSchema{} = series, now \\ Clock.utc_now()) do
    occurrences = SeriesQueries.list_occurrences(series)
    upcoming = Enum.count(occurrences, &Cancel.cancellable?(&1, now))
    payment = taken_payment(series)

    %{
      series: Repo.preload(series, :meeting_type),
      sessions: Enum.map(occurrences, &organizer_session(&1, now)),
      upcoming: upcoming,
      open_request: Cancel.open_request?(series),
      payment: payment,
      remaining_refund_cents: remaining_refund(series, payment, upcoming)
    }
  end

  defp organizer_session(%Meeting{} = meeting, now),
    do: organizer_session(meeting, meeting.series_position, status(meeting, true, now), false)

  defp organizer_session(%Participant{meeting: %Meeting{} = meeting} = seat, now) do
    status = status(meeting, Participant.live?(seat), now)
    organizer_session(meeting, seat.series_position, status, true)
  end

  defp organizer_session(meeting, position, status, seat?) do
    %{
      position: position,
      meeting: meeting,
      start_time: meeting.start_time,
      status: status,
      seat: seat?
    }
  end

  defp taken_payment(%SeriesSchema{id: id}) do
    case MeetingPayments.payment_for_series(id) do
      %{paid_at: %DateTime{}} = payment -> payment
      _unpaid_or_none -> nil
    end
  end

  defp remaining_refund(_series, nil, _count), do: 0

  defp remaining_refund(series, payment, count),
    do: Cancel.remaining_share_cents(series, payment, count)

  defp session(%Meeting{} = meeting, organizer_profile, open_request, now) do
    status = status(meeting, true, now)

    build(meeting, meeting.series_position, status, open_request, fn ->
      meeting |> MeetingLinks.for_meeting(organizer_profile) |> urls()
    end)
  end

  defp session(%Participant{meeting: %Meeting{} = meeting} = seat, _profile, open_request, now) do
    status = status(meeting, Participant.live?(seat), now)

    build(meeting, seat.series_position, status, open_request, fn -> seat_links(meeting, seat) end)
  end

  defp build(meeting, position, status, open_request, links_fn) do
    %{
      position: position,
      meeting: meeting,
      start_time: meeting.start_time,
      status: status,
      links: links(status, open_request, links_fn)
    }
  end

  defp links(:upcoming, _open_request, links_fn), do: links_fn.()

  # A session held on its own is cancelled as a single request is; it has
  # no time to move to until the host answers.
  defp links(:awaiting_approval, false, links_fn) do
    case links_fn.() do
      %{cancel_url: cancel_url} -> %{reschedule_url: nil, cancel_url: cancel_url}
      nil -> nil
    end
  end

  defp links(_status, _open_request, _links_fn), do: nil

  # A seat given up is cancelled whatever its session became.
  defp status(_meeting, false = _live_seat, _now), do: :cancelled
  defp status(%Meeting{status: :completed}, _live, _now), do: :past

  defp status(%Meeting{} = meeting, _live, now) do
    cond do
      MeetingState.terminal?(meeting) -> :cancelled
      MeetingState.awaiting_approval?(meeting) -> :awaiting_approval
      MeetingState.awaiting_payment?(meeting) -> :awaiting_payment
      DateTime.compare(meeting.start_time, now) != :gt -> :past
      true -> :upcoming
    end
  end

  # The booker's own links for their seat, as their emails carry them.
  defp seat_links(meeting, %Participant{management_token: token} = seat) when is_binary(token) do
    meeting
    |> Recipient.as_seen_by(Recipient.from_participant(seat))
    |> urls()
  end

  defp seat_links(_meeting, _seat_without_token), do: nil

  defp urls(%{reschedule_url: reschedule_url, cancel_url: cancel_url}),
    do: %{reschedule_url: reschedule_url, cancel_url: cancel_url}

  defp paid?(%SeriesSchema{id: id}) do
    case MeetingPayments.payment_for_series(id) do
      %{status: status} -> status in @paid_statuses
      nil -> false
    end
  end
end
