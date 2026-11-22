defmodule Tymeslot.Notifications.Relevance do
  @moduledoc """
  When each time-bound notification stops mattering.

  Most notifications are owed however late they run: they record that
  somebody acted. A few exist only to prompt or inform somebody before a
  moment (a reminder before the meeting, a nudge before an approval
  deadline, word that a request expired),
  and delivered after it they are noise. A sweep catching up on old rows, a
  restored backup or a long outage would otherwise send them all at once.

  The moment travels with the job as `"relevant_until"`: email jobs are
  checked by `Tymeslot.Emails.EmailActions.relevant?/2` when they run. Slack
  and Telegram messages are checked as they are fanned out
  (`Tymeslot.Notifications.ChannelFanout`): their deliveries retry for
  seconds, not days, so the lateness that matters is upstream, a sweep or a
  delayed automation job reaching the fan-out late. Webhooks are never
  checked: they keep an integration in step with the meeting's state, and a
  late one is still the truth. `nil` means owed however late.
  """

  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.EventTypes

  # News of a request that lapsed is announced at its deadline, which can fall
  # on or after the meeting's start, so the start alone cannot bound it. The
  # grace past the deadline covers any realistic delay in a sweep or a mail
  # queue.
  @late_news_grace_seconds 7 * 86_400

  @requested EventTypes.to_event_type(:meeting_requested)
  @request_expired EventTypes.to_event_type(:meeting_request_expired)

  @doc "Whether a notification relevant until `moment` is still worth sending at `now`."
  @spec relevant?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def relevant?(nil, %DateTime{}), do: true
  def relevant?(%DateTime{} = moment, %DateTime{} = now), do: DateTime.compare(now, moment) != :gt

  @doc """
  A Slack or Telegram message about a single booking's `event_type` (its wire
  name): the request the host must answer, until its approval deadline, and
  word that it expired, as for its email. Every other event is owed.
  """
  @spec channel_event(String.t(), map()) :: DateTime.t() | nil
  def channel_event(@requested, meeting), do: approval_request(meeting)
  def channel_event(@request_expired, meeting), do: request_expiry(meeting)
  def channel_event(_event_type, _meeting), do: nil

  @doc "A reminder, or anything else about the meeting itself: its start."
  @spec meeting_start(map()) :: DateTime.t() | nil
  def meeting_start(%{start_time: start}), do: start

  @doc """
  A reschedule request, asking the attendee to pick a new time: its deadline
  (`MeetingState.reschedule_request_deadline/1`), after which no answer is
  taken. It follows the meeting's start, so its email reads it from the
  meeting when it runs rather than carrying it
  (`Tymeslot.Notifications.Email.RescheduleRequestEmails.check_answerable/1`).
  """
  @spec reschedule_request(map()) :: DateTime.t() | nil
  def reschedule_request(meeting), do: MeetingState.reschedule_request_deadline(meeting)

  @doc """
  The news that a reschedule request lapsed unanswered, to either side: a
  week past the request's deadline.
  """
  @spec reschedule_lapse(map()) :: DateTime.t() | nil
  def reschedule_lapse(meeting) do
    case MeetingState.reschedule_request_deadline(meeting) do
      %DateTime{} = deadline -> after_grace(deadline)
      nil -> nil
    end
  end

  @doc """
  A booking request waiting on the host, or a nudge to answer it: its
  approval deadline, after which the host can no longer answer. `nil` for a
  request with no deadline.
  """
  @spec approval_request(map()) :: DateTime.t() | nil
  def approval_request(%{approval_deadline_at: deadline}), do: deadline

  @doc """
  The news that a booking request expired: the meeting's start, or the grace
  past the approval deadline if that is later. A request made inside its
  approval window has its deadline capped at the start, so it expires as the
  meeting starts and the start alone would drop every such notice; the grace
  keeps it owed while a backlog months old is still dropped.

  `nil` for a booking a reschedule sent back into the gate
  (`first_announced_at` set): its expiry cancels a meeting people were told
  was confirmed, and its original time is not on the row, so that news is
  owed however late.
  """
  @spec request_expiry(map()) :: DateTime.t() | nil
  def request_expiry(%{first_announced_at: nil} = meeting), do: expiry_news_until([meeting])
  def request_expiry(_regated), do: nil

  @doc """
  The news that a series request expired: the start of its last session, or
  the grace past the latest approval deadline if that is later, as for
  `request_expiry/1`. `nil` when any session had been announced as
  confirmed.
  """
  @spec series_expiry([map()]) :: DateTime.t() | nil
  def series_expiry([_first | _rest] = sessions) do
    if Enum.all?(sessions, &is_nil(&1.first_announced_at)),
      do: expiry_news_until(sessions),
      else: nil
  end

  def series_expiry([]), do: nil

  defp expiry_news_until(sessions) do
    graced_deadlines =
      for %{approval_deadline_at: %DateTime{} = deadline} <- sessions, do: after_grace(deadline)

    sessions
    |> Enum.map(& &1.start_time)
    |> Enum.concat(graced_deadlines)
    |> Enum.max(DateTime)
  end

  defp after_grace(deadline), do: DateTime.add(deadline, @late_news_grace_seconds, :second)

  @doc "A reminder to vote in a poll: the poll's deadline."
  @spec poll_deadline(map()) :: DateTime.t() | nil
  def poll_deadline(%{deadline_at: deadline}), do: deadline
end
