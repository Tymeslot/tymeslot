defmodule Tymeslot.Polls.Voting do
  @moduledoc """
  Participant registration and vote casting for meeting polls.

  This is the write path behind the public voting page: a person registers with
  their name and email (resuming a prior registration for the same email), then
  casts one response per candidate slot. Both operations refuse to proceed once
  voting has closed, and vote casting whitelists slot ids against the poll rather
  than trusting client-supplied ids.
  """

  alias Tymeslot.Polls

  alias Tymeslot.Polls.{
    PollParticipantQueries,
    PollParticipantSchema,
    PollSchema,
    PollVoteQueries
  }

  alias Tymeslot.Repo

  @unique_email_constraint "poll_participants_poll_id_email_index"

  @doc """
  Registers a participant on `poll` from `attrs` (`name`, `email`, optional
  `timezone` and `locale`; string or atom keys).

  Registration is idempotent per email: a repeated registration for an email
  already on the poll resumes the existing participant rather than erroring. This
  is a deliberate trade-off, someone who returns to the voting page keeps their
  identity and previous votes, at the cost of not distinguishing two people who
  share an address.

  Returns `{:error, :voting_closed}` when voting has closed and
  `{:error, :poll_full}` once the participant cap is reached.
  """
  @spec register_participant(PollSchema.t(), map()) ::
          {:ok, PollParticipantSchema.t()}
          | {:error, :voting_closed | :poll_full | Ecto.Changeset.t()}
  def register_participant(poll, attrs) do
    if Polls.voting_open?(poll) do
      register_open(poll, attrs)
    else
      {:error, :voting_closed}
    end
  end

  @doc """
  Casts `votes_map` (`%{slot_id => response}`) for the participant identified by
  `participant_token`.

  Responses may be atoms (`:yes`, `:if_need_be`, `:no`) or their string forms
  (`"yes"`, `"if_need_be"`/`"if-need-be"`, `"no"`), as sent by the web layer.
  `poll` must have its `:time_slots` preloaded, they are the whitelist every slot
  id is checked against.

  An empty `votes_map` is a no-op that returns the participant without stamping
  `voted_at`, the participant has not yet expressed anything.

  Returns `{:error, :voting_closed}`, `{:error, :unknown_participant}`,
  `{:error, :invalid_slot}`, or `{:error, :invalid_response}` on the respective
  failure.
  """
  @spec cast_votes(PollSchema.t(), String.t(), %{optional(Ecto.UUID.t()) => String.t() | atom()}) ::
          {:ok, PollParticipantSchema.t()}
          | {:error, :voting_closed | :unknown_participant | :invalid_slot | :invalid_response}
  def cast_votes(poll, participant_token, votes_map) do
    with :ok <- ensure_open(poll),
         {:ok, participant} <- resolve_participant(poll, participant_token) do
      cast_for_participant(poll, participant, votes_map)
    end
  end

  # --- Registration helpers ---

  defp register_open(poll, attrs) do
    email = normalise_email(attrs)

    case PollParticipantQueries.get_by_poll_and_email(poll.id, email) do
      %PollParticipantSchema{} = existing -> {:ok, existing}
      nil -> insert_participant(poll, attrs, email)
    end
  end

  # The cap is a best-effort soft limit: this is a check-then-insert, so
  # concurrent registrations with distinct emails could overshoot the max
  # slightly. That is acceptable here, so no advisory lock is taken.
  defp insert_participant(poll, attrs, email) do
    if PollParticipantQueries.count_for_poll(poll.id) >= PollSchema.max_participants() do
      {:error, :poll_full}
    else
      %PollParticipantSchema{}
      |> PollParticipantSchema.creation_changeset(participant_attrs(poll, attrs, email))
      |> PollParticipantQueries.insert()
      |> handle_insert(poll, email)
    end
  end

  defp participant_attrs(poll, attrs, email) do
    %{
      poll_id: poll.id,
      name: fetch(attrs, :name),
      email: email,
      timezone: fetch(attrs, :timezone),
      locale: fetch(attrs, :locale)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # On the unique-constraint race (a concurrent registration for the same email
  # slipped in between the existence check and this insert) resume the participant
  # that now exists. Any other changeset error is a genuine failure.
  defp handle_insert({:ok, participant}, _poll, _email), do: {:ok, participant}

  defp handle_insert({:error, changeset}, poll, email) do
    if unique_email_violation?(changeset) do
      {:ok, PollParticipantQueries.get_by_poll_and_email(poll.id, email)}
    else
      {:error, changeset}
    end
  end

  defp unique_email_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint_name) == @unique_email_constraint
    end)
  end

  defp normalise_email(attrs) do
    case fetch(attrs, :email) do
      email when is_binary(email) -> email |> String.trim() |> String.downcase()
      _other -> nil
    end
  end

  defp fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  # --- Vote casting helpers ---

  defp ensure_open(poll) do
    if Polls.voting_open?(poll), do: :ok, else: {:error, :voting_closed}
  end

  defp resolve_participant(poll, token) do
    case PollParticipantQueries.get_by_token(token) do
      nil -> {:error, :unknown_participant}
      participant -> validate_participant_poll(participant, poll.id)
    end
  end

  defp validate_participant_poll(%{poll_id: poll_id} = participant, poll_id),
    do: {:ok, participant}

  defp validate_participant_poll(_participant, _poll_id), do: {:error, :unknown_participant}

  defp cast_for_participant(_poll, participant, votes_map) when map_size(votes_map) == 0 do
    {:ok, participant}
  end

  defp cast_for_participant(poll, participant, votes_map) do
    with :ok <- validate_slots(poll, votes_map),
         {:ok, vote_maps} <- build_vote_maps(participant, votes_map) do
      persist(poll, participant, vote_maps)
    end
  end

  defp validate_slots(%{time_slots: time_slots}, votes_map) do
    slot_ids = MapSet.new(time_slots, & &1.id)

    if Enum.all?(Map.keys(votes_map), &MapSet.member?(slot_ids, &1)) do
      :ok
    else
      {:error, :invalid_slot}
    end
  end

  defp build_vote_maps(participant, votes_map) do
    Enum.reduce_while(votes_map, {:ok, []}, fn {slot_id, response}, {:ok, acc} ->
      case normalise_response(response) do
        {:ok, normalised} ->
          vote = %{
            poll_participant_id: participant.id,
            poll_time_slot_id: slot_id,
            response: normalised
          }

          {:cont, {:ok, [vote | acc]}}

        :error ->
          {:halt, {:error, :invalid_response}}
      end
    end)
  end

  defp normalise_response(response) when response in [:yes, :if_need_be, :no], do: {:ok, response}
  defp normalise_response("yes"), do: {:ok, :yes}
  defp normalise_response("no"), do: {:ok, :no}

  defp normalise_response(response) when response in ["if_need_be", "if-need-be"],
    do: {:ok, :if_need_be}

  defp normalise_response(_other), do: :error

  # Upsert and voted_at stamp must land together: Task 11's all-voted
  # notification keys off voted_at, so a vote persisted without the stamp would
  # be invisible to it. Broadcast only after the transaction commits.
  defp persist(poll, participant, vote_maps) do
    transaction =
      Repo.transaction(fn ->
        PollVoteQueries.upsert_votes(vote_maps)
        {:ok, stamped} = stamp_voted(participant)
        stamped
      end)

    case transaction do
      {:ok, stamped} ->
        Polls.broadcast_update(poll.id)
        maybe_notify_all_voted(poll)
        {:ok, stamped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stamp_voted(participant) do
    participant
    |> PollParticipantSchema.voted_changeset(DateTime.utc_now())
    |> PollParticipantQueries.update()
  end

  # Task 11 replaces this no-op with the "everyone has voted" host notification.
  defp maybe_notify_all_voted(_poll), do: :ok
end
