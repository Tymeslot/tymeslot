defmodule Tymeslot.Polls.Voting do
  @moduledoc """
  Voting-link requests and vote casting for meeting polls.

  This is the write path behind the public voting page. A visitor asks for a
  voting link with their name and email; the link is emailed and never shown
  on the page, so holding it proves they own the address. Responses can only be
  cast through that link, and the first time they are saved confirms the
  participant: from then on they count. Both operations refuse to proceed once
  voting has closed, and vote casting whitelists slot ids against the poll
  rather than trusting client-supplied ids.
  """

  alias Tymeslot.Emails.EmailScheduler.PollScheduler
  alias Tymeslot.Polls

  alias Tymeslot.Polls.{
    PollParticipantQueries,
    PollParticipantSchema,
    PollSchema,
    PollVoteQueries
  }

  alias Tymeslot.Repo

  @unique_email_constraint "poll_participants_poll_id_email_index"

  # A repeat request for the same address within this window sends nothing:
  # anyone can type any address, so the form must not become a way to flood
  # someone's inbox.
  @resend_interval_seconds 10 * 60

  @doc """
  Emails a personal voting link to the address in `attrs` (`name`, `email`,
  optional `timezone` and `locale`; string or atom keys).

  An address new to the poll becomes an unconfirmed participant. An address
  already on it, confirmed or not, gets its existing link again, at most once
  per #{div(@resend_interval_seconds, 60)} minutes; its name is left as it
  was. Both return `:ok`, so the answer never tells a visitor whether an
  address takes part.

  Returns `{:error, :voting_closed}` once voting has closed,
  `{:error, :poll_full}` when the participant cap is reached, and
  `{:error, :too_many_requests}` when too many links are out unconfirmed.
  """
  @spec request_link(PollSchema.t(), map()) ::
          :ok | {:error, :voting_closed | :poll_full | :too_many_requests | Ecto.Changeset.t()}
  def request_link(poll, attrs) do
    if Polls.voting_open?(poll) do
      request_open(poll, attrs)
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

  The first responses an unconfirmed participant saves confirm them, provided
  the poll still has room (`{:error, :poll_full}` otherwise), and send them a
  receipt carrying their link.

  Returns `{:error, :voting_closed}`, `{:error, :unknown_participant}`,
  `{:error, :invalid_slot}`, `{:error, :invalid_response}` or
  `{:error, :poll_full}` on the respective failure.
  """
  @spec cast_votes(PollSchema.t(), String.t(), %{optional(Ecto.UUID.t()) => String.t() | atom()}) ::
          {:ok, PollParticipantSchema.t()}
          | {:error,
             :voting_closed
             | :unknown_participant
             | :invalid_slot
             | :invalid_response
             | :poll_full}
  def cast_votes(poll, participant_token, votes_map) do
    with :ok <- ensure_open(poll),
         {:ok, participant} <- resolve_participant(poll, participant_token) do
      cast_for_participant(poll, participant, votes_map)
    end
  end

  @doc """
  Returns the participant on `poll` identified by `token`, with votes
  preloaded, or `nil`.

  The token is the per-person `?p=` value from the voting link. A token that
  belongs to a different poll, an unknown token, an unconfirmed participant's
  expired token, and a non-string value all return `nil`, so a participant can
  never be resolved across polls.
  """
  @spec get_participant(PollSchema.t(), term()) :: PollParticipantSchema.t() | nil
  def get_participant(%PollSchema{id: poll_id}, token) when is_binary(token),
    do: PollParticipantQueries.get_by_poll_and_token(poll_id, token)

  def get_participant(%PollSchema{}, _token), do: nil

  # --- Link request helpers ---

  defp request_open(poll, attrs) do
    email = normalise_email(attrs)

    case find_existing(poll, email) do
      %PollParticipantSchema{} = existing -> resend_link(existing)
      nil -> insert_participant(poll, attrs, email)
    end
  end

  # A missing address fails the changeset; looking it up would raise first.
  defp find_existing(_poll, nil), do: nil

  defp find_existing(poll, email),
    do: PollParticipantQueries.get_by_poll_and_email(poll.id, email)

  # The send is claimed by a conditional update, so two requests racing for
  # the same address send one email between them.
  defp resend_link(participant) do
    now = DateTime.utc_now()
    resend_before = DateTime.add(now, -@resend_interval_seconds, :second)

    if PollParticipantQueries.claim_link_send(participant.id, now, resend_before) do
      PollScheduler.schedule_participant_link(participant)
    else
      :ok
    end
  end

  # Both caps are best-effort soft limits: this is a check-then-insert, so
  # concurrent requests with distinct emails could overshoot them slightly.
  # That is acceptable here, so no advisory lock is taken.
  defp insert_participant(poll, attrs, email) do
    cond do
      PollParticipantQueries.count_confirmed(poll.id) >= PollSchema.max_participants() ->
        {:error, :poll_full}

      PollParticipantQueries.count_unconfirmed(poll.id) >=
          PollSchema.max_unconfirmed_participants() ->
        {:error, :too_many_requests}

      true ->
        %PollParticipantSchema{}
        |> PollParticipantSchema.creation_changeset(participant_attrs(poll, attrs, email))
        |> PollParticipantSchema.link_sent_changeset(DateTime.utc_now())
        |> PollParticipantQueries.insert()
        |> handle_insert()
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

  defp handle_insert({:ok, participant}), do: PollScheduler.schedule_participant_link(participant)

  # On the unique-constraint race a concurrent request for the same address
  # inserted first, and its link is already on the way. Any other changeset
  # error is a genuine failure.
  defp handle_insert({:error, changeset}) do
    if unique_email_violation?(changeset), do: :ok, else: {:error, changeset}
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
    case get_participant(poll, token) do
      nil -> {:error, :unknown_participant}
      participant -> {:ok, participant}
    end
  end

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
        case ensure_room(poll, participant) do
          :ok ->
            PollVoteQueries.upsert_votes(vote_maps)
            {:ok, stamped} = stamp_voted(participant)
            stamped

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case transaction do
      {:ok, stamped} ->
        Polls.broadcast_update(poll.id)
        maybe_send_receipt(participant, stamped)
        maybe_notify_all_voted(poll)
        {:ok, stamped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Confirming adds the participant to the count the cap is about. Best-effort
  # like the check on request.
  defp ensure_room(_poll, %PollParticipantSchema{confirmed_at: %DateTime{}}), do: :ok

  defp ensure_room(poll, _participant) do
    if PollParticipantQueries.count_confirmed(poll.id) < PollSchema.max_participants() do
      :ok
    else
      {:error, :poll_full}
    end
  end

  # One receipt, when the participant is confirmed. Later changes are saved
  # silently: the receipt already holds the link to come back with.
  defp maybe_send_receipt(%PollParticipantSchema{confirmed_at: nil}, stamped),
    do: PollScheduler.schedule_vote_receipt(stamped)

  defp maybe_send_receipt(_participant, _stamped), do: :ok

  defp stamp_voted(participant) do
    participant
    |> PollParticipantSchema.voted_changeset(DateTime.utc_now())
    |> PollParticipantQueries.update()
  end

  # Once everyone who asked for a link has voted, nudge the host to pick a time.
  # The count is re-checked against the database rather than the (now stale)
  # in-memory poll, since the just-cast vote stamped voted_at inside the
  # transaction above.
  defp maybe_notify_all_voted(poll) do
    if all_participants_voted?(poll) do
      PollScheduler.schedule_all_voted_nudge(poll)
    end

    :ok
  end

  defp all_participants_voted?(poll) do
    PollParticipantQueries.count_confirmed(poll.id) > 0 and
      not PollParticipantQueries.awaiting_votes?(poll.id)
  end
end
