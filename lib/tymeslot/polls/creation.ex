defmodule Tymeslot.Polls.Creation do
  @moduledoc """
  Creates a poll with its candidate slots and first invitees, behind
  `Tymeslot.Polls.create_poll/2`, which documents the attributes it takes and
  the errors it returns.

  The poll, its slots and its invitations are written in one transaction.
  The deadline nudge and the invitation emails are sent once it commits.
  """

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Polls

  alias Tymeslot.Polls.{
    HostReadiness,
    Invitations,
    MeetingTypeRule,
    PollQueries,
    PollSchema,
    Slots
  }

  alias Tymeslot.Repo

  @doc "See `Tymeslot.Polls.create_poll/2`."
  @spec create_poll(integer(), map()) :: {:ok, PollSchema.t()} | {:error, term()}
  def create_poll(user_id, attrs) do
    with :ok <- HostReadiness.ensure_calendar(user_id),
         :ok <- HostReadiness.ensure_username(user_id, Map.get(attrs, :invitees, [])),
         {:ok, attrs} <- apply_meeting_type(user_id, attrs),
         {:ok, slots} <- prepare_slots(attrs) do
      insert_poll(user_id, attrs, slots)
    end
  end

  defp put_default_access(attrs, invitees) do
    case Map.get(attrs, :invite_only) do
      nil -> Map.put(attrs, :invite_only, Polls.default_invite_only?(invitees))
      _chosen -> attrs
    end
  end

  defp apply_meeting_type(_user_id, %{meeting_type_id: nil} = attrs), do: {:ok, attrs}

  defp apply_meeting_type(user_id, %{meeting_type_id: meeting_type_id} = attrs) do
    with {:ok, meeting_type} <- MeetingTypeRule.fetch(meeting_type_id, user_id),
         do: {:ok, snapshot_meeting_type(attrs, meeting_type)}
  end

  defp apply_meeting_type(_user_id, attrs), do: {:ok, attrs}

  # A poll takes the type's *primary* duration, deliberately, even for a type
  # that offers several lengths: a poll asks a group to agree on one slot, so
  # the length has to be settled before the candidates go out, and the host is
  # the one who settles it rather than each invitee. `Map.put_new/3` leaves a
  # length the host passed in untouched, which is where another one is chosen.
  defp snapshot_meeting_type(attrs, meeting_type) do
    attrs
    |> Map.put_new(:title, meeting_type.name)
    |> Map.put_new(:duration_minutes, meeting_type.duration_minutes)
  end

  defp prepare_slots(attrs) do
    case Map.get(attrs, :slots, []) do
      [] -> {:error, :no_slots}
      slots -> build_slots(slots, Map.get(attrs, :duration_minutes))
    end
  end

  defp build_slots(slots, duration) do
    # Lazily, so the check stops at the first slot in the past.
    with :ok <- Slots.check_count(length(slots)),
         :ok <- slots |> Stream.map(& &1.start_time) |> Slots.check_future() do
      {:ok,
       slots
       |> Enum.with_index()
       |> Enum.map(fn {slot, index} -> build_slot(slot, index, duration) end)}
    end
  end

  defp build_slot(slot, index, duration) do
    %{start_time: slot.start_time, end_time: end_time_for(slot, duration), position: index}
  end

  defp end_time_for(slot, duration) do
    case {Map.get(slot, :end_time), duration} do
      {nil, minutes} when is_integer(minutes) ->
        DateTime.add(slot.start_time, minutes * 60, :second)

      {nil, _minutes} ->
        nil

      {end_time, _minutes} ->
        end_time
    end
  end

  defp insert_poll(user_id, attrs, slots) do
    {invitees, attrs} = Map.pop(attrs, :invitees, [])

    poll_attrs =
      attrs
      |> put_default_access(invitees)
      |> Map.put(:user_id, user_id)
      |> Map.drop([:slots])

    transaction =
      Repo.transaction(fn ->
        with {:ok, poll} <-
               PollQueries.insert(PollSchema.creation_changeset(%PollSchema{}, poll_attrs)),
             {:ok, _slots} <- Slots.insert(poll, slots) do
          {poll, Invitations.insert(poll, invitees)}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case transaction do
      {:ok, {poll, invitations}} ->
        :ok = EmailScheduler.schedule_poll_deadline_nudge(poll)
        :ok = Invitations.send_invitations(invitations.invited)
        {:ok, PollQueries.get_for_user(poll.id, user_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
