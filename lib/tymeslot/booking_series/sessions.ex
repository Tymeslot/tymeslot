defmodule Tymeslot.BookingSeries.Sessions do
  @moduledoc """
  Where each session of a series stands, as its booker sees it on the
  series page (`/:username/series/:series_uid`): every session in series
  order with its status and, for one still to come, its own reschedule and
  cancel links; how many sessions "Cancel all remaining" would call off;
  whether the series is still an open approval request; and whether a
  payment was taken for it.

  A session is one of:

    * `:upcoming` - live and still to start; the only status with links,
      the booker's own meeting links on a one-to-one series and their
      seat's links on a group one;
    * `:past` - started or over;
    * `:cancelled` - cancelled, a request that lapsed, or a seat given up;
    * `:awaiting_approval` - held for the host's decision;
    * `:awaiting_payment` - held for the series' checkout.

  `upcoming` counts the sessions `Tymeslot.BookingSeries.Cancel` cancels for
  an attendee: the live ones still to come. Held sessions are not among
  them, as the cancellation leaves them to the request or the checkout.
  """

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.BookingSeries.Approval
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
    sessions = Enum.map(occurrences, &session(&1, organizer_profile, now))

    %{
      series: Repo.preload(series, :meeting_type),
      sessions: sessions,
      upcoming: Enum.count(sessions, &(&1.status == :upcoming)),
      held_for_approval: Enum.count(sessions, &(&1.status == :awaiting_approval)),
      open_request: open_request?(sessions),
      paid: paid?(series)
    }
  end

  defp session(%Meeting{} = meeting, organizer_profile, now) do
    status = status(meeting, true, now)

    build(meeting, meeting.series_position, status, fn ->
      meeting |> MeetingLinks.for_meeting(organizer_profile) |> urls()
    end)
  end

  defp session(%Participant{meeting: %Meeting{} = meeting} = seat, _organizer_profile, now) do
    status = status(meeting, Participant.live?(seat), now)
    build(meeting, seat.series_position, status, fn -> seat_links(meeting, seat) end)
  end

  defp build(meeting, position, status, links_fn) do
    %{
      position: position,
      meeting: meeting,
      start_time: meeting.start_time,
      status: status,
      links: if(status == :upcoming, do: links_fn.())
    }
  end

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

  defp open_request?(sessions) do
    case Enum.find(sessions, &(&1.status == :awaiting_approval)) do
      nil -> false
      %{meeting: meeting} -> Approval.series_request?(meeting)
    end
  end

  defp paid?(%SeriesSchema{id: id}) do
    case MeetingPayments.payment_for_series(id) do
      %{status: status} -> status in @paid_statuses
      nil -> false
    end
  end
end
