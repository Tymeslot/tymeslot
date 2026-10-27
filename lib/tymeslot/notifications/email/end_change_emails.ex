defmodule Tymeslot.Notifications.Email.EndChangeEmails do
  @moduledoc """
  Sends the notices for a booking whose end the host moved in their own
  calendar (`Tymeslot.Meetings.ExternalCalendarChanges.apply_end_change/2`).
  The booker, or every live participant of a group meeting, and every live
  guest get the new end with an updated calendar entry. The host is then told
  who was notified.

  What each seat hears comes from the seat, not from the job: the end change
  write leaves on every seat the end it last knew (`notified_end_time`), and
  this job tells each seat whose known end differs from the meeting's current
  one, then records the end it told. So however many jobs a run of changes
  produces (a change while one waits, runs or retries), each seat hears
  "the end it knew, then the end that stands" once, and a seat that already
  knows the current end (the end was moved back, an earlier job told it, it
  joined after the change) is not written to. A seat told the current end
  keeps it recorded rather than going back to nil: the next change would
  seed the same end either way, and clearing it could race a change landing
  in between and lose the end that seat knew. A reschedule clears every seat,
  since its own emails state the new times.

  The job waits a little before it runs (`EndChangeScheduler`), so a host
  dragging the end several times sends one notice. It carries the start it
  was scheduled against: a meeting moved since is overtaken.

  Each send is claimed on the job (`DeliveryClaims`), so a retry writes only
  to whoever was missed, and the host's notice still counts the seats an
  earlier run reached. A transient failure retries the job; an address the
  provider rejects for good is not retried. The host's notice goes out once
  nobody is left to retry and at least one attendee or guest was reached:
  when nobody was, the host is not told that they were.

  Two jobs for one meeting running at the same instant (a retry's backoff
  landing exactly while the next job runs) could both tell a seat. That race
  is accepted: closing it would mean claiming each seat's end before sending.

  Chat channels and webhooks are not told: the booking did not move.
  """

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Clock
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingCalendarQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.DeliveryClaims

  @not_confirmed "Meeting not confirmed"
  @slot_void "Meeting time no longer holds"
  @meeting_started "Meeting already started"
  @start_moved "Meeting start moved"
  @nothing_to_tell "Every seat knows the current end"
  @host_leaving "Host account pending deletion"

  # What the host's notice states the change replaced, kept on the job
  # (`DeliveryClaims.remember/3`).
  @host_from "end_change:host_from"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do:
      reason in [
        @not_confirmed,
        @slot_void,
        @meeting_started,
        @start_moved,
        @nothing_to_tell,
        @host_leaving
      ]

  @doc """
  Tells every seat whose known end differs from the meeting's current one,
  unless the booking has moved on since the job was scheduled: no longer
  confirmed, its time voided, already started, its start moved, or its host
  leaving.
  """
  @spec handle_end_change_emails(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_end_change_emails(%{"meeting_id" => meeting_id, "start_time" => start_time}, job_id) do
    {:ok, start_time, _offset} = DateTime.from_iso8601(start_time)

    MeetingEmails.with_meeting(meeting_id, "end change emails", fn meeting ->
      case overtaken(meeting, start_time) do
        nil ->
          send_notices(meeting, job_id)

        reason ->
          Logger.info("Skipping end change emails overtaken by a later change",
            meeting_id: meeting_id,
            reason: reason
          )

          {:discard, reason}
      end
    end)
  end

  defp overtaken(meeting, start_time) do
    cond do
      not MeetingState.confirmed?(meeting) -> @not_confirmed
      MeetingState.slot_void?(meeting) -> @slot_void
      not DateTime.after?(meeting.start_time, Clock.utc_now()) -> @meeting_started
      DateTime.compare(meeting.start_time, start_time) != :eq -> @start_moved
      host_leaving?(meeting) -> @host_leaving
      true -> nil
    end
  end

  defp host_leaving?(%{organizer_user_id: user_id}) when is_integer(user_id),
    do: Auth.deletion_pending?(user_id)

  defp host_leaving?(_meeting), do: false

  defp send_notices(meeting, job_id) do
    # Taken before any seat is told: telling the booker moves the meeting's
    # record on, and a retry must still give the host the end it replaced.
    host_from = host_previous_end(job_id, meeting.notified_end_time)
    outcomes = attendee_outcomes(meeting, job_id) ++ guest_outcomes(meeting, job_id)

    cond do
      outcomes == [] ->
        {:discard, @nothing_to_tell}

      Enum.any?(outcomes, &match?({:failed, _who}, &1)) ->
        {:error, "End change notices failed for some recipients"}

      Enum.any?(outcomes, &match?({:sent, _who, _told}, &1)) ->
        notify_host(meeting, outcomes, host_from, job_id)

      true ->
        Logger.warning("End change reached no attendee; the host is not told it did",
          meeting_id: meeting.id
        )

        :ok
    end
  end

  # The booker of a solo meeting, or each live participant of a group one,
  # with the meeting rendered as they see it (their own seat's calendar
  # entry, for a participant).
  defp attendee_outcomes(meeting, job_id) do
    meeting
    |> Meetings.recipients()
    |> Enum.flat_map(fn recipient ->
      seat = %{
        key: "end_change:#{recipient_key(recipient)}",
        who: {recipient.kind, recipient.name || recipient.email},
        known_end: recipient.notified_end_time,
        record: fn end_time -> record_attendee(meeting, recipient, end_time) end
      }

      tell(seat, meeting, job_id, fn known_end ->
        details =
          meeting
          |> AppointmentBuilder.from_meeting(recipient, nil)
          |> Map.put(:original_end_time, known_end)

        Config.email_service_module().send_end_change_to_attendee(recipient.email, details)
      end)
    end)
  end

  defp guest_outcomes(meeting, job_id) do
    fallback = AppointmentBuilder.from_meeting(meeting)

    meeting.id
    |> GuestQueries.list_live_for_meeting()
    |> GuestNotifications.with_inviter_details(meeting, fallback)
    |> Enum.flat_map(fn {guest, details} ->
      seat = %{
        key: "end_change:guest:#{guest.id}",
        who: {:guest, guest.name || guest.email},
        known_end: guest.notified_end_time,
        record: &GuestQueries.put_notified_end(guest.id, &1)
      }

      tell(seat, meeting, job_id, fn known_end ->
        details =
          details
          |> Map.put(:original_end_time, known_end)
          |> GuestNotifications.guest_details(guest)

        Config.email_service_module().send_guest_end_change(guest.email, details)
      end)
    end)
  end

  # One seat's outcome, or none when it has nothing to hear: it was reached
  # by an earlier run of this job (counted, not sent again), or it already
  # knows the meeting's current end. Otherwise it is told the end it knew
  # and the current one, and the current one is recorded as what it knows.
  defp tell(seat, meeting, job_id, send) do
    cond do
      DeliveryClaims.claimed?(job_id, seat.key) ->
        [{:sent, seat.who, nil}]

      not pending?(seat.known_end, meeting.end_time) ->
        []

      true ->
        result =
          DeliveryClaims.once(job_id, seat.key, fn ->
            with {:ok, _sent} = sent <- send.(seat.known_end) do
              seat.record.(meeting.end_time)
              sent
            end
          end)

        [outcome(result, seat, meeting)]
    end
  end

  defp pending?(nil, _end_time), do: false
  defp pending?(known_end, end_time), do: DateTime.compare(known_end, end_time) != :eq

  defp record_attendee(_meeting, %Recipient{kind: :participant, participant_id: id}, end_time),
    do: ParticipantQueries.put_notified_end(id, end_time)

  defp record_attendee(meeting, %Recipient{}, end_time),
    do: MeetingCalendarQueries.put_notified_end(meeting.id, end_time)

  defp recipient_key(%Recipient{kind: :participant, participant_id: id}), do: "participant:#{id}"
  defp recipient_key(%Recipient{}), do: "attendee"

  # A claim an earlier run made (`:ok`) is a send that went out.
  defp outcome(:ok, seat, _meeting), do: {:sent, seat.who, seat.known_end}
  defp outcome({:ok, _result}, seat, _meeting), do: {:sent, seat.who, seat.known_end}

  defp outcome({:error, reason}, %{who: who}, meeting) do
    if Delivery.permanent_rejection?(reason) do
      Logger.warning("End change notice rejected for good",
        meeting_id: meeting.id,
        recipient_kind: elem(who, 0)
      )

      {:rejected, who}
    else
      Logger.error("End change notice failed",
        meeting_id: meeting.id,
        recipient_kind: elem(who, 0),
        reason: LogFormat.reason(reason)
      )

      {:failed, who}
    end
  end

  # The host hears the end the attendees knew: the meeting's own record of
  # it as the job's first run found it, which every change seeds, or failing
  # that the end a reached seat knew. A group meeting has no booker seat, so
  # its record is moved on here, once the host's notice has gone out or been
  # refused for good: before that, a retry could find it already moved.
  defp notify_host(meeting, outcomes, host_from, job_id) do
    reached = for {:sent, who, _known_end} <- outcomes, do: who

    notice = %{
      previous_end_time: host_from || host_previous_end(job_id, first_known_end(outcomes)),
      attendees: for({kind, name} <- reached, kind != :guest, do: name),
      guests: Enum.count(reached, &match?({:guest, _name}, &1))
    }

    result =
      DeliveryClaims.once(job_id, "end_change:host", fn ->
        Config.email_service_module().send_end_change_to_organizer(
          meeting,
          meeting.organizer_email,
          notice
        )
      end)

    case outcome(result, %{who: {:organizer, meeting.organizer_name}, known_end: nil}, meeting) do
      {:failed, _who} ->
        {:error, "End change notice to the host failed"}

      _sent_or_rejected ->
        if MeetingSchema.group?(meeting),
          do: MeetingCalendarQueries.put_notified_end(meeting.id, meeting.end_time)

        :ok
    end
  end

  # The first value a run of this job took, kept with its claims
  # (`DeliveryClaims.remember/3`).
  # With nothing to offer, an earlier run's value still stands.
  defp host_previous_end(job_id, nil),
    do: job_id |> DeliveryClaims.recall(@host_from) |> parse_instant()

  defp host_previous_end(job_id, %DateTime{} = known_end) do
    job_id
    |> DeliveryClaims.remember(@host_from, DateTime.to_iso8601(known_end))
    |> parse_instant()
  end

  defp parse_instant(nil), do: nil

  defp parse_instant(iso8601) do
    {:ok, instant, _offset} = DateTime.from_iso8601(iso8601)
    instant
  end

  defp first_known_end(outcomes),
    do:
      Enum.find_value(outcomes, fn
        {:sent, _who, known_end} -> known_end
        _other -> nil
      end)
end
