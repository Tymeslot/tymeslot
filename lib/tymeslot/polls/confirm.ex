defmodule Tymeslot.Polls.Confirm do
  @moduledoc """
  Confirms a poll by minting a real meeting from a chosen candidate slot.

  Confirmation runs the winning slot through the regular ad-hoc booking path
  (`Bookings.CreateAdHoc`), so the resulting meeting gets the same calendar
  sync, notifications and optional video provisioning as any other booking. The
  first participant available for the slot becomes the attendee; everyone else
  rides along as a guest. On success the poll transitions to `:confirmed` and
  subscribers are notified.
  """

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Emails.EmailScheduler.PollScheduler
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollQueries, PollSchema, PollTimeSlotQueries}
  alias Tymeslot.Repo

  @available_responses [:yes, :if_need_be]

  @type reason ::
          :not_found
          | :not_open
          | :invalid_slot
          | :slot_in_past
          | :no_participants
          | :slot_taken
          | Ecto.Changeset.t()
          | String.t()

  @doc """
  Confirms `poll_id` on `slot_id` for its owner `user_id`.

  Returns `{:ok, meeting}` on success, or `{:error, reason}` when the poll is
  missing, not open, the slot is invalid or past, there are no participants, the
  slot is already taken for the host, or the underlying booking fails.
  """
  @spec confirm(Ecto.UUID.t(), Ecto.UUID.t(), integer()) ::
          {:ok, Tymeslot.Meetings.MeetingSchema.t()} | {:error, reason()}
  def confirm(poll_id, slot_id, user_id) do
    case Repo.transaction(fn -> claim_and_mint(poll_id, slot_id, user_id) end) do
      {:ok, meeting} ->
        # Both effects belong after the commit: the cache must not be rebuilt
        # from a meeting that is still uncommitted, and subscribers must not be
        # told about a confirmation that could still roll back.
        AvailabilityCache.invalidate_for_user(user_id)
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
         {:ok, primary} <- resolve_primary(poll, slot),
         {:ok, meeting} <- create_meeting(poll, slot, primary),
         {:ok, _poll} <-
           PollQueries.update(PollSchema.confirm_changeset(poll, confirm_attrs(meeting))) do
      PollScheduler.cancel_deadline_jobs(poll.id)
      meeting
    else
      # Nothing here may query: a failing booking has already rolled back the
      # transaction at its own level, which leaves the connection able to do
      # nothing but roll back.
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_poll(poll_id, user_id) do
    case PollQueries.lock_for_user(poll_id, user_id) do
      nil -> {:error, :not_found}
      poll -> {:ok, poll}
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
    case PollTimeSlotQueries.get_for_poll(slot_id, poll.id) do
      nil -> {:error, :invalid_slot}
      slot -> ensure_future(slot)
    end
  end

  defp ensure_future(slot) do
    if DateTime.compare(slot.start_time, DateTime.utc_now()) == :gt do
      {:ok, slot}
    else
      {:error, :slot_in_past}
    end
  end

  defp resolve_primary(%PollSchema{participants: []}, _slot), do: {:error, :no_participants}

  defp resolve_primary(%PollSchema{participants: participants}, slot) do
    {:ok, pick_primary(participants, slot.id)}
  end

  defp pick_primary(participants, slot_id) do
    Enum.find(participants, List.first(participants), &available_for?(&1, slot_id))
  end

  defp available_for?(participant, slot_id) do
    Enum.any?(participant.votes, fn vote ->
      vote.poll_time_slot_id == slot_id and vote.response in @available_responses
    end)
  end

  defp guest_emails(participants, primary) do
    participants
    |> Enum.reject(&(&1.id == primary.id))
    |> Enum.map(& &1.email)
    |> Enum.reject(&(&1 == primary.email))
    |> Enum.uniq()
  end

  defp integration_ids(%PollSchema{meeting_type_id: nil} = poll) do
    {primary_calendar_id(poll.user_id), nil}
  end

  defp integration_ids(%PollSchema{meeting_type_id: meeting_type_id} = poll) do
    case MeetingTypes.get_meeting_type(meeting_type_id, poll.user_id) do
      nil -> {primary_calendar_id(poll.user_id), nil}
      meeting_type -> {meeting_type.calendar_integration_id, meeting_type.video_integration_id}
    end
  end

  defp primary_calendar_id(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, integration} -> integration.id
      {:error, _reason} -> nil
    end
  end

  defp create_meeting(poll, slot, primary) do
    {calendar_integration_id, video_integration_id} = integration_ids(poll)

    %{
      title: poll.title,
      start_time: slot.start_time,
      end_time: slot.end_time,
      organizer_user_id: poll.user_id,
      attendee_name: primary.name,
      attendee_email: primary.email,
      attendee_timezone: primary.timezone || poll.timezone,
      calendar_integration_id: calendar_integration_id,
      video_integration_id: video_integration_id,
      guest_emails: guest_emails(poll.participants, primary)
    }
    |> CreateAdHoc.execute()
    |> map_booking_result()
  end

  defp map_booking_result({:ok, meeting}), do: {:ok, meeting}
  defp map_booking_result({:error, :time_conflict}), do: {:error, :slot_taken}
  defp map_booking_result({:error, reason}), do: {:error, reason}
end
