defmodule Tymeslot.Polls.Confirm do
  @moduledoc """
  Confirms a poll by minting a real meeting from a chosen candidate slot.

  Confirmation runs the winning slot through the regular ad-hoc booking path
  (`Bookings.CreateAdHoc`), so the resulting meeting gets the same calendar
  sync, notifications and optional video provisioning as any other booking. On
  success the poll transitions to `:confirmed` and subscribers are notified.

  The meeting is managed by the host (`MeetingSchema.managed_by_host?/1`): it
  has no booker. Every participant is invited as a guest and answers yes or no
  like one, and only the host can move or cancel it. The first participant
  available for the slot fills the meeting's attendee fields, which a calendar
  entry needs, but is not sent the booking emails with their reschedule and
  cancel links.

  A host may take part in their own poll, to give their own answers next to
  everyone else's. That entry is left out of the meeting: the host is its
  organiser, so they are neither its attendee nor one of its guests.
  """

  alias Ecto.UUID
  alias Tymeslot.Availability
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantSchema, PollQueries, PollSchema, PollTimeSlotQueries}
  alias Tymeslot.Repo

  @available_responses [:yes, :if_need_be]

  @type reason ::
          :not_found
          | :not_open
          | :invalid_slot
          | :slot_in_past
          | :no_participants
          | :slot_taken
          | :time_off
          | Ecto.Changeset.t()
          | String.t()

  @doc """
  Confirms `poll_id` on `slot_id` for its owner `user_id`.

  Returns `{:ok, meeting}` on success, or `{:error, reason}` when the poll is
  missing, not open, the slot is invalid or past, the slot falls inside the
  host's time off (`:time_off`), there are no participants besides the host
  (`:no_participants`), another of the host's meetings overlaps the slot
  (`:slot_taken`), or the underlying booking fails. The host chose the time,
  so their buffers do not pad it, as they do not when the host later moves the
  meeting (`Tymeslot.Bookings.HostMove`).

  Both ids arrive as event params, so either may be anything: a `poll_id`
  that is not a UUID is `:not_found`, and a `slot_id` that is not one of the
  poll's times, UUID or not, is `:invalid_slot`.

  Time off is checked here rather than in `Bookings.CreateAdHoc`, which also
  serves the calendar grid and deliberately skips every schedule rule. A poll
  is answered days after the host proposed its times, so a holiday entered in
  between must still stop it being confirmed into.
  """
  @spec confirm(term(), term(), integer()) ::
          {:ok, Tymeslot.Meetings.MeetingSchema.t()} | {:error, reason()}
  def confirm(poll_id, slot_id, user_id) do
    case Repo.transaction(fn -> claim_and_mint(poll_id, slot_id, user_id) end) do
      {:ok, {meeting, pending}} ->
        # All three belong after the commit: the integration fan-out must not
        # be able to roll the confirmation back, the cache must not be rebuilt
        # from a meeting that is still uncommitted, and subscribers must not be
        # told about a confirmation that could still roll back.
        :ok = Activation.after_commit(pending)
        Availability.changed(user_id)
        Polls.broadcast_update(poll_id)
        {:ok, meeting}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Everything that decides whether the poll may be confirmed, and everything
  # that acts on that decision, commits as one transaction opened by a locking
  # read. The meeting and the status flip therefore land together or not at
  # all, so no crash, timeout or restart can strand a minted meeting against a
  # poll that still reads as open.
  defp claim_and_mint(poll_id, slot_id, user_id) do
    with {:ok, poll} <- lock_poll(poll_id, user_id),
         :ok <- ensure_open(poll),
         {:ok, slot} <- resolve_slot(poll, slot_id),
         :ok <- TimeOff.ensure_clear(poll.user_id, slot.start_time, slot.end_time),
         invitees = invitees(poll),
         {:ok, primary} <- resolve_primary(invitees, slot),
         {:ok, meeting, pending} <- create_meeting(poll, slot, primary, invitees),
         {:ok, _poll} <-
           PollQueries.update(PollSchema.confirm_changeset(poll, confirm_attrs(meeting))) do
      EmailScheduler.cancel_poll_deadline_jobs(poll.id)
      {meeting, pending}
    else
      # Nothing here may query: a failing booking has already rolled back the
      # transaction at its own level, which leaves the connection able to do
      # nothing but roll back.
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Both ids come from the dashboard's event params, so a forged one that is
  # not a UUID is answered as one that matches nothing rather than raising
  # in the query.
  defp lock_poll(poll_id, user_id) do
    with {:ok, poll_id} <- UUID.cast(poll_id),
         %PollSchema{} = poll <- PollQueries.lock_for_user(poll_id, user_id) do
      {:ok, poll}
    else
      _forged_or_not_found -> {:error, :not_found}
    end
  end

  defp confirm_attrs(meeting) do
    %{
      status: :confirmed,
      confirmed_meeting_id: meeting.id,
      confirmed_at: DateTime.utc_now(:second)
    }
  end

  defp ensure_open(%PollSchema{status: :open}), do: :ok
  defp ensure_open(_poll), do: {:error, :not_open}

  defp resolve_slot(poll, slot_id) do
    with {:ok, slot_id} <- UUID.cast(slot_id),
         %{} = slot <- PollTimeSlotQueries.get_for_poll(slot_id, poll.id) do
      ensure_future(slot)
    else
      _forged_or_not_found -> {:error, :invalid_slot}
    end
  end

  defp ensure_future(slot) do
    if DateTime.compare(slot.start_time, DateTime.utc_now()) == :gt do
      {:ok, slot}
    else
      {:error, :slot_in_past}
    end
  end

  # The participants the meeting is for: everyone but the host's own entry,
  # matched by address as `Bookings.CreateAdHoc` matches a self-booking.
  defp invitees(%PollSchema{participants: participants} = poll) do
    host_email = normalise_email(Repo.preload(poll, :user).user.email)
    Enum.reject(participants, &(normalise_email(&1.email) == host_email))
  end

  defp normalise_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalise_email(_email), do: nil

  defp resolve_primary([], _slot), do: {:error, :no_participants}
  defp resolve_primary(invitees, slot), do: {:ok, pick_primary(invitees, slot.id)}

  defp pick_primary(participants, slot_id) do
    Enum.find(participants, List.first(participants), &available_for?(&1, slot_id))
  end

  defp available_for?(participant, slot_id) do
    Enum.any?(participant.votes, fn vote ->
      vote.poll_time_slot_id == slot_id and vote.response in @available_responses
    end)
  end

  # Every invitee, the primary included: they are a guest like the rest, under the
  # name they gave, so their emails and the host's name them. Each keeps their
  # own language and timezone (the poll's where they gave none, as for the
  # primary), so their emails reach them as they read the poll.
  defp guests(participants, poll) do
    participants
    |> Enum.map(
      &%{
        email: String.downcase(&1.email),
        name: &1.name,
        locale: &1.locale,
        timezone: &1.timezone || poll.timezone
      }
    )
    |> Enum.uniq_by(& &1.email)
  end

  # The calendar the meeting is written to is chosen as a booking of the
  # poll's meeting type would choose it: the type's own calendar where it names
  # one the host can still book into, otherwise the host's booking calendar.
  # The video integration is the meeting type's, and none without one.
  defp integrations(%PollSchema{} = poll) do
    case meeting_type(poll) do
      nil ->
        Map.put(calendar_target(poll.user_id), :video_integration_id, nil)

      meeting_type ->
        Map.put(
          calendar_target(meeting_type),
          :video_integration_id,
          meeting_type.video_integration_id
        )
    end
  end

  defp meeting_type(%PollSchema{meeting_type_id: nil}), do: nil

  defp meeting_type(%PollSchema{meeting_type_id: meeting_type_id, user_id: user_id}),
    do: MeetingTypes.get_meeting_type(meeting_type_id, user_id)

  defp calendar_target(context) do
    case CalendarEvents.get_booking_integration_info(context) do
      {:ok, %{integration_id: integration_id, calendar_path: calendar_path}} ->
        %{calendar_integration_id: integration_id, calendar_path: calendar_path}

      _no_integration ->
        %{calendar_integration_id: nil, calendar_path: nil}
    end
  end

  defp create_meeting(poll, slot, primary, invitees) do
    poll
    |> integrations()
    |> Map.merge(%{
      title: poll.title,
      start_time: slot.start_time,
      end_time: slot.end_time,
      organizer_user_id: poll.user_id,
      attendee_name: PollParticipantSchema.display_name(primary),
      attendee_email: primary.email,
      attendee_timezone: primary.timezone || poll.timezone,
      attendee_locale: primary.locale,
      guest_emails: guests(invitees, poll),
      managed_by_host: true,
      # What the host wrote to the participants while they voted is still
      # their note to them once the meeting is set.
      organizer_note: organizer_note(poll.description)
    })
    |> CreateAdHoc.execute_deferred(buffers: false)
    |> map_booking_result()
  end

  # Polls created before their description was capped can hold more than a
  # note may. Cut it to fit rather than let an over-long description stop the
  # host confirming the poll at all.
  defp organizer_note(description) when is_binary(description),
    do: description |> String.trim() |> String.slice(0, MeetingSchema.organizer_note_max_length())

  defp organizer_note(nil), do: nil

  defp map_booking_result({:ok, meeting, pending}), do: {:ok, meeting, pending}
  defp map_booking_result({:error, :time_conflict}), do: {:error, :slot_taken}
  defp map_booking_result({:error, reason}), do: {:error, reason}
end
