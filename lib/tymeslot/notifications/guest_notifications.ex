defmodule Tymeslot.Notifications.GuestNotifications do
  @moduledoc """
  Keeps a booking's guests informed when the booking changes after they were
  invited.

  A guest receives an invitation with RSVP links when a booking is confirmed
  (`Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails`). Before this module a
  guest heard nothing more: not when the booking moved, and not when it was
  cancelled. Here:

    * **Rescheduled** (`notify_rescheduled/2`): every guest's answer and
      reminder history is reset, since both applied to the previous time, and
      every guest, including those who declined, gets a reschedule email with
      their RSVP links and an updated calendar entry.
    * **Rescheduled into the approval gate** (`prepare_for_reapproval/1`): no
      email yet, since nobody has agreed to the new time; the answers and
      reminder history are reset. Once the host approves the new time
      (`notify_reapproved/1`), the guests who had been invited get the
      reschedule email. A request that was never approved has guests who were
      never invited; the confirmation that follows its approval invites them
      as usual.
    * **Cancelled, declined or expired** (`notify_cancelled/3`): every guest gets
      a cancellation email, but only for a booking that was ever confirmed. A
      request that was never approved never invited anyone.

  On a group meeting only the guests of participants still holding their seat
  are written to (`GuestQueries.list_live_for_meeting/1`), and each guest's
  email is rendered from their own participant's view of the meeting
  (`with_inviter_details/4`): that participant's language, timezone and seat
  calendar entry, not the slot row's.

  Guest emails never fail the operation that triggered them: a failed send is
  logged, and the booking and the host's and booker's emails are unaffected.
  """

  require Logger

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Recipient

  @doc """
  Resets the guests' answers and reminder history, and sends each guest the
  reschedule email.

  `content` is the reschedule payload built by
  `Tymeslot.Notifications.ContentBuilder.build_reschedule_details/2`.
  """
  @spec notify_rescheduled(map(), map()) :: :ok
  def notify_rescheduled(%{id: meeting_id} = _meeting, content) do
    case GuestQueries.list_live_for_meeting(meeting_id) do
      [] ->
        :ok

      guests ->
        GuestQueries.reset_for_new_time(meeting_id)

        guests
        |> Enum.map(&{&1, content})
        |> send_to_guests(meeting_id, "reschedule", fn guest, details ->
          Config.email_service_module().send_guest_reschedule(guest.email, details)
        end)
    end
  end

  @doc """
  Prepares the guests of a booking that a reschedule sent back into the
  approval gate: their answers and reminder history applied to the previous
  time and are reset. Nobody is emailed until the host approves the new time.
  """
  @spec prepare_for_reapproval(map()) :: :ok
  def prepare_for_reapproval(%{id: meeting_id}) do
    GuestQueries.reset_for_new_time(meeting_id)
    :ok
  end

  @doc """
  Sends the reschedule email to the guests who had been invited, once the host
  approves a booking that a reschedule sent back into the approval gate.

  Only a booking that was confirmed before has invited guests, so for a first
  approval this sends nothing and the confirmation invites the guests instead.
  The previous time is no longer known at this point, so the email states the
  new time without it.
  """
  @spec notify_reapproved(map()) :: :ok
  def notify_reapproved(%{id: meeting_id} = meeting) do
    case Enum.reject(
           GuestQueries.list_live_for_meeting(meeting_id),
           &is_nil(&1.confirmation_sent_at)
         ) do
      [] ->
        :ok

      invited ->
        details = AppointmentBuilder.from_meeting(meeting)

        invited
        |> Enum.map(&{&1, details})
        |> send_to_guests(meeting_id, "reschedule", fn guest, details ->
          Config.email_service_module().send_guest_reschedule(guest.email, details)
        end)
    end
  end

  @doc """
  Sends each guest the cancellation email, for a booking that was confirmed at
  some point and so had invited them. `appointment_details` is the payload of
  `Tymeslot.Emails.AppointmentBuilder.from_meeting/1`.

  `once` wraps each guest's send, given a key naming that guest and the send
  itself. A job that must not mail a guest twice passes
  `&Tymeslot.Workers.DeliveryClaims.once(job, &1, &2)`, so a rescued run
  skips the guests already told and still reaches the rest.
  """
  @spec notify_cancelled(map(), map(), (String.t(), (-> term()) -> term())) :: :ok
  def notify_cancelled(meeting, appointment_details, once \\ fn _key, send -> send.() end)

  def notify_cancelled(meeting, appointment_details, once) do
    if ever_confirmed?(meeting),
      do: send_cancellations(meeting, appointment_details, once),
      else: :ok
  end

  defp send_cancellations(%{id: meeting_id} = meeting, appointment_details, once) do
    meeting_id
    |> GuestQueries.list_live_for_meeting()
    |> with_inviter_details(meeting, appointment_details)
    |> send_to_guests(meeting_id, "cancellation", fn guest, details ->
      once.("cancellation:guest:#{guest.id}", fn ->
        Config.email_service_module().send_guest_cancellation(guest.email, details)
      end)
    end)
  end

  @doc """
  Sends each of `guests` of `meeting` the cancellation of the seat that
  brought them, from `seat_details`, that seat's payload (its calendar entry,
  its participant's language and timezone). Used when a participant cancels or moves their
  seat while the meeting carries on: the meeting-level cancellation never
  reaches these guests, since their seat is no longer live.

  Only guests who were sent an invitation are told; one never invited has
  nothing in their calendar to cancel. Declined guests are told like the
  others, as on a cancelled booking: the entry may still be in their
  calendar. `once` wraps each send as in `notify_cancelled/3`.
  """
  @spec notify_seat_cancelled(
          map(),
          [GuestSchema.t()],
          map(),
          (String.t(), (-> term()) -> term())
        ) :: :ok
  def notify_seat_cancelled(%{id: meeting_id}, guests, seat_details, once) do
    guests
    |> Enum.reject(&is_nil(&1.confirmation_sent_at))
    |> Enum.map(&{&1, seat_details})
    |> send_to_guests(meeting_id, "seat cancellation", fn guest, details ->
      once.("seat_cancellation:guest:#{guest.id}", fn ->
        Config.email_service_module().send_guest_cancellation(guest.email, details)
      end)
    end)
  end

  @doc """
  Pairs each guest with the payload their emails are rendered from.

  A group-booking guest (`:participant` preloaded, as
  `GuestQueries.list_live_for_meeting/1` and `list_for_reminder/3` return
  them) gets their own participant's view of the meeting, built once per
  participant: that participant's locale and timezone, and the seat's own
  calendar UID and revision, so the entry in the guest's calendar is the
  same event as their participant's. Any other guest gets `fallback`, the
  meeting's own payload. `reminder` is passed through to the builder.
  """
  @spec with_inviter_details([GuestSchema.t()], map(), map(), map() | nil) ::
          [{GuestSchema.t(), map()}]
  def with_inviter_details(guests, meeting, fallback, reminder \\ nil)

  def with_inviter_details(guests, %MeetingSchema{} = meeting, fallback, reminder) do
    by_participant =
      guests
      |> Enum.flat_map(fn
        %{participant: %ParticipantSchema{} = participant} -> [participant]
        _guest -> []
      end)
      |> Enum.uniq_by(& &1.id)
      |> Map.new(fn participant ->
        {participant.id,
         AppointmentBuilder.from_meeting(
           meeting,
           Recipient.from_participant(participant),
           reminder
         )}
      end)

    Enum.map(guests, fn guest ->
      {guest, Map.get(by_participant, guest.participant_id, fallback)}
    end)
  end

  def with_inviter_details(guests, _meeting, fallback, _reminder),
    do: Enum.map(guests, &{&1, fallback})

  @doc """
  Tells the guests of a held request the host declined, or that expired, that
  the booking is off. Only a request a reschedule sent back into the gate had
  invited guests; `notify_cancelled/3` sends nothing for any other.
  """
  @spec notify_released(map()) :: :ok
  def notify_released(%{first_announced_at: nil}), do: :ok

  def notify_released(meeting),
    do: notify_cancelled(meeting, AppointmentBuilder.from_meeting(meeting))

  # What the booker told the host and nobody else: their address, their
  # message, their contact details, and their answers to the booking form
  # (with the questions, so the guest's calendar entry does not list them
  # unanswered). The booker's name stays, since a guest is told who arranged
  # the meeting and the event title already carries it.
  @booker_private_keys [
    :attendee_email,
    :attendee_message,
    :attendee_phone,
    :attendee_company,
    :custom_field_answers,
    :custom_fields_snapshot
  ]

  @doc """
  The appointment details for one guest: the shared payload, less the booker's
  private details, plus the guest's name, personal RSVP links, and who invited
  them (`:guest_invited_by`, `:booker` or `:organizer`), which decides whom
  their emails name.

  Every guest email, and the calendar entry attached to it, is rendered from
  this map, so nothing private to the booker can reach a guest through any of
  them. The fields that make the guest's calendar entry the same event as the
  booker's (`:uid`, the organiser, `:ical_sequence`) are kept as they are.

  A group-booking guest was invited by their own participant, not by whoever
  the meeting row names as its attendee, so when the guest arrives with its
  participant loaded that participant is who the email says invited them.
  """
  @spec guest_details(map(), map()) :: map()
  def guest_details(appointment_details, guest) do
    urls = Policy.guest_rsvp_urls(guest.rsvp_token)

    appointment_details
    |> Map.drop(@booker_private_keys)
    |> put_inviting_participant(guest)
    |> Map.put(:guest_name, guest.name || guest.email)
    |> Map.put(:guest_accept_url, urls.accept_url)
    |> Map.put(:guest_decline_url, urls.decline_url)
    |> Map.put(:guest_invited_by, GuestSchema.inviter(guest))
  end

  defp put_inviting_participant(details, %{participant: %ParticipantSchema{} = participant}),
    do: Map.put(details, :attendee_name, participant.name || participant.email)

  defp put_inviting_participant(details, _guest), do: details

  # A group meeting is confirmed from its first seat and never passes through
  # the announcement claim (each seat is announced on its own), so it carries
  # no `first_announced_at` even though its guests were invited.
  defp ever_confirmed?(%{first_announced_at: %DateTime{}}), do: true
  defp ever_confirmed?(%MeetingSchema{} = meeting), do: MeetingSchema.group?(meeting)
  defp ever_confirmed?(_meeting), do: false

  defp send_to_guests(guests_with_details, meeting_id, kind, send_fun) do
    Enum.each(guests_with_details, fn {guest, appointment_details} ->
      case send_fun.(guest, guest_details(appointment_details, guest)) do
        {:ok, _result} ->
          :ok

        # Already sent by an earlier run of the same job (see `notify_cancelled/3`).
        :ok ->
          :ok

        other ->
          Logger.error("Guest email failed",
            email_kind: kind,
            meeting_id: meeting_id,
            result: LogFormat.reason(other)
          )
      end
    end)
  end
end
