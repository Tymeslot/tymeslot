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

  Link emails count against the poll email limits
  (`Tymeslot.Polls.EmailLimits`): a poll takes so many requests an hour, and an
  address is sent so many poll emails, across every poll.
  """

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Polls

  alias Tymeslot.Polls.{
    EmailLimits,
    PollParticipantQueries,
    PollParticipantSchema,
    PollQueries,
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
  How long after a participant's link was emailed another email with it
  waits, whoever asks for it: the participant on the voting page or the host
  from the dashboard.
  """
  @spec resend_interval_seconds() :: pos_integer()
  def resend_interval_seconds, do: @resend_interval_seconds

  @typedoc """
  What a link request did: sent a new participant their link (`:sent`), sent
  a known address its link again (`:resent`), or held back a known address's
  link that went out moments ago (`:throttled`).
  """
  @type request_outcome :: :sent | :resent | :throttled

  @doc """
  Emails a personal voting link to the address in `attrs` (`name`, `email`,
  optional `timezone` and `locale`; string or atom keys).

  The whole request is checked first, by the rules a new participant must
  meet, whether or not the address is already on the poll. Then:

    * an address new to the poll becomes an unconfirmed participant and is
      sent its link: `{:ok, :sent}`;
    * an unconfirmed address whose pending link has expired is treated as new:
      the old row is deleted and a new link is sent, `{:ok, :sent}`, with
      both caps applying;
    * an address already on the poll is sent its existing link again,
      `{:ok, :resent}`, or nothing if it went out within the last
      #{div(@resend_interval_seconds, 60)} minutes, `{:ok, :throttled}`.
      An unconfirmed participant takes the request's name, timezone and
      locale; a confirmed one keeps their own.

  The outcome tells the visitor whether the address was already on the poll.
  That is deliberate: the page says so rather than pretend otherwise.

  Returns `{:error, :invite_only}` when only the people the host invited can
  vote, checked before anything else, so nothing is written or sent and no
  existing link is sent again; `{:error, changeset}` for an invalid request;
  `{:error, :voting_closed}` once voting has closed or while the poll's host
  is pending account deletion; and, for a new address or one whose pending
  link has expired, `{:error, :poll_full}` at the participant cap and
  `{:error, :too_many_requests}` when too many links are out unconfirmed or
  the poll has taken its share of requests this hour, and
  `{:error, :recipient_rate_limited}` when the address has had too many poll
  emails lately.
  """
  @spec request_link(PollSchema.t(), map()) ::
          {:ok, request_outcome()}
          | {:error,
             :invite_only
             | :voting_closed
             | :poll_full
             | :too_many_requests
             | :recipient_rate_limited
             | Changeset.t()}
  def request_link(poll, attrs) do
    # Every refusal is one clause here, run before anything is written or
    # sent, so a new check (who may ask, how often) is one more clause.
    with :ok <- ensure_requests_accepted(poll),
         :ok <- ensure_open(poll),
         {:ok, request} <- validate_request(poll, attrs),
         :ok <- EmailLimits.charge_link_request(poll) do
      route_request(poll, request)
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
  the poll still has room (`{:error, :poll_full}` otherwise). Anyone's first
  saved responses send them a receipt carrying their link.

  A participant the host invited without a name gives it with their first
  responses, as the `:name` option; without a valid one nothing is saved and
  the name changeset is returned.

  On an invite-only poll an unconfirmed participant, a link request that
  slipped in as the host switched the poll, cannot confirm:
  `{:error, :invite_only}`, and nothing is saved.

  Returns `{:error, :voting_closed}` (also while the poll's host is pending
  account deletion), `{:error, :unknown_participant}`, `{:error, :invalid_slot}`,
  `{:error, :invalid_response}`, `{:error, :poll_full}`, `{:error, :invite_only}`
  or `{:error, changeset}` on the respective failure.
  """
  @spec cast_votes(
          PollSchema.t(),
          String.t(),
          %{optional(Ecto.UUID.t()) => String.t() | atom()},
          keyword()
        ) ::
          {:ok, PollParticipantSchema.t()}
          | {:error,
             :voting_closed
             | :unknown_participant
             | :invalid_slot
             | :invalid_response
             | :poll_full
             | :invite_only
             | Changeset.t()}
  def cast_votes(poll, participant_token, votes_map, opts \\ []) do
    with :ok <- ensure_open(poll),
         {:ok, participant} <- resolve_participant(poll, participant_token) do
      cast_for_participant(poll, participant, votes_map, Keyword.get(opts, :name))
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

  # An invite-only poll asks nobody for their address: its people are the
  # ones the host invited, each holding their link. Read fresh, so a page
  # loaded before the host switched cannot get a request in.
  defp ensure_requests_accepted(%PollSchema{id: poll_id}), do: refuse_if_invite_only(poll_id)

  # The request is checked in full before the address is looked up, so a
  # known address cannot slip a name past the rules a new one must meet.
  defp validate_request(poll, attrs) do
    changeset =
      PollParticipantSchema.creation_changeset(
        %PollParticipantSchema{},
        participant_attrs(poll, attrs)
      )

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp route_request(poll, request) do
    case PollParticipantQueries.get_by_poll_and_email(poll.id, request_email(request)) do
      nil ->
        insert_participant(poll, request)

      %PollParticipantSchema{confirmed_at: nil} = pending ->
        restart_if_expired(poll, pending, request)

      %PollParticipantSchema{} = confirmed ->
        refresh_and_resend(poll, confirmed, request)
    end
  end

  # An expired link stays dead: the request starts over as a new one, with a
  # new link whose lifetime runs from now, and meets the caps like any new
  # request. Reviving the old row instead would let each resend extend it.
  defp restart_if_expired(poll, pending, request) do
    case PollParticipantQueries.delete_if_expired(pending.id) do
      {1, _rows} -> insert_participant(poll, request)
      {0, _rows} -> refresh_and_resend(poll, pending, request)
    end
  end

  # An unconfirmed participant's details are whatever the latest request
  # gave. The update is conditional, so a confirmed participant's are never
  # touched, even by a request racing the confirmation.
  defp refresh_and_resend(poll, participant, request) do
    PollParticipantQueries.update_unconfirmed_details(
      participant.id,
      PollParticipantSchema.request_details(request)
    )

    case resend_link(participant) do
      {:ok, :throttled} -> confirm_still_known(poll, request)
      resent -> resent
    end
  end

  # An expired unconfirmed row can be pruned between the lookup and the
  # claim, which then touches nothing; the address is new again.
  defp confirm_still_known(poll, request) do
    case PollParticipantQueries.get_by_poll_and_email(poll.id, request_email(request)) do
      nil -> insert_participant(poll, request)
      %PollParticipantSchema{} -> {:ok, :throttled}
    end
  end

  # The send is claimed by a conditional update, so two requests racing for
  # the same address send one email between them. Only a claimed send is
  # charged to the address: a repeat inside the window sends nothing. A
  # refused charge releases the claim, so the stamp does not make a retry
  # look like a link sent minutes ago when nothing was sent.
  defp resend_link(participant) do
    now = DateTime.utc_now()
    resend_before = DateTime.add(now, -@resend_interval_seconds, :second)

    if PollParticipantQueries.claim_link_send(participant.id, now, resend_before) do
      case EmailLimits.charge_recipient(participant.email) do
        :ok ->
          EmailScheduler.schedule_poll_participant_link(participant)
          {:ok, :resent}

        {:error, _reason} = refused ->
          PollParticipantQueries.release_link_send(
            participant.id,
            now,
            participant.link_sent_at
          )

          refused
      end
    else
      {:ok, :throttled}
    end
  end

  # Both caps are best-effort soft limits: this is a check-then-insert, so
  # concurrent requests with distinct emails could overshoot them slightly.
  # That is acceptable here, so no advisory lock is taken.
  defp insert_participant(poll, request) do
    cond do
      PollParticipantQueries.count_confirmed(poll.id) >= PollSchema.max_participants() ->
        {:error, :poll_full}

      PollParticipantQueries.count_unconfirmed(poll.id) >=
          PollSchema.max_unconfirmed_participants() ->
        {:error, :too_many_requests}

      true ->
        # Charged before the row is written, so a refused address leaves no
        # participant waiting for a link that never comes. A write that then
        # fails or loses the unique-constraint race keeps the charge,
        # deliberately: it is rare and errs towards sending less.
        with :ok <- EmailLimits.charge_recipient(request_email(request)) do
          request
          |> PollParticipantSchema.link_sent_changeset(DateTime.utc_now())
          |> insert_under_poll_lock(poll)
          |> handle_insert(poll, request)
        end
    end
  end

  # The poll is held `FOR SHARE` before the row is written. Postgres checks
  # the row's reference to its poll only after writing it, so without the
  # lock a request arriving while the host invites the same address would
  # write its row, then wait for the host's lock on the poll while the host
  # waits on that row: a deadlock. Taken first, the request waits for the
  # host's invitations to commit and then meets the address as a known one.
  # The lock also settles a host switching the poll to invite-only meanwhile:
  # the request reads the poll as the switch left it, so it cannot write a
  # row the switch's withdrawal has already passed over.
  defp insert_under_poll_lock(changeset, poll) do
    Repo.transaction(fn ->
      case PollQueries.lock_shared(poll.id) do
        %PollSchema{invite_only: true} -> Repo.rollback(:invite_only)
        _open_or_gone -> insert_or_rollback(changeset)
      end
    end)
  end

  defp insert_or_rollback(changeset) do
    case PollParticipantQueries.insert(changeset) do
      {:ok, participant} -> participant
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp participant_attrs(poll, attrs) do
    %{
      poll_id: poll.id,
      name: fetch(attrs, :name),
      email: fetch(attrs, :email),
      timezone: fetch(attrs, :timezone),
      locale: fetch(attrs, :locale)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp handle_insert({:ok, participant}, _poll, _request) do
    EmailScheduler.schedule_poll_participant_link(participant)
    {:ok, :sent}
  end

  defp handle_insert({:error, :invite_only} = refused, _poll, _request), do: refused

  # On the unique-constraint race a concurrent request for the same address
  # inserted first, so this one turns out to be a request for a known
  # address. Any other changeset error is a genuine failure.
  defp handle_insert({:error, changeset}, poll, request) do
    with true <- unique_email_violation?(changeset),
         %PollParticipantSchema{} = existing <-
           PollParticipantQueries.get_by_poll_and_email(poll.id, request_email(request)) do
      refresh_and_resend(poll, existing, request)
    else
      _not_a_known_address -> {:error, changeset}
    end
  end

  defp unique_email_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint_name) == @unique_email_constraint
    end)
  end

  # `creation_changeset/2` has trimmed and lowercased it already.
  defp request_email(request), do: Changeset.get_field(request, :email)

  defp fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  # --- Vote casting helpers ---

  # A voting page opened before its host asked to delete their account can
  # still submit; the poll is about to go, so it takes no more names or votes.
  defp ensure_open(%PollSchema{user_id: user_id} = poll) do
    if PollSchema.voting_open?(poll) and not Auth.deletion_pending?(user_id),
      do: :ok,
      else: {:error, :voting_closed}
  end

  defp resolve_participant(poll, token) do
    case get_participant(poll, token) do
      nil -> {:error, :unknown_participant}
      participant -> {:ok, participant}
    end
  end

  defp cast_for_participant(_poll, participant, votes_map, _name) when map_size(votes_map) == 0 do
    {:ok, participant}
  end

  defp cast_for_participant(poll, participant, votes_map, name) do
    with :ok <- validate_slots(poll, votes_map),
         {:ok, vote_maps} <- build_vote_maps(participant, votes_map) do
      persist(poll, participant, vote_maps, name)
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
  defp persist(poll, participant, vote_maps, name) do
    transaction =
      Repo.transaction(fn ->
        with {:ok, current} <- lock_poll(poll),
             :ok <- ensure_open(current),
             {:ok, locked} <- lock_participant(poll, participant),
             :ok <- ensure_admitted(current, locked),
             :ok <- ensure_room(poll, locked),
             {:ok, named} <- ensure_named(locked, name) do
          PollVoteQueries.upsert_votes(vote_maps)
          {:ok, stamped} = stamp_voted(named)
          {locked, stamped}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case transaction do
      {:ok, {locked, stamped}} ->
        Polls.broadcast_update(poll.id)
        maybe_send_receipt(locked, stamped)
        maybe_update_host(poll)
        notify_host_if_all_voted(poll)
        {:ok, stamped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The poll as it stands, held `FOR SHARE` until the votes are in and taken
  # before the participant's row, the order the host's writes lock in. A host
  # closing the poll or moving its deadline waits for the vote in progress;
  # a vote starting after the host's write commits checks voting is open
  # against what the host left, not against the page's copy. Gone already,
  # voting is closed.
  defp lock_poll(poll) do
    case PollQueries.lock_shared(poll.id) do
      nil -> {:error, :voting_closed}
      current -> {:ok, current}
    end
  end

  # Holds the participant's row until the votes are in, so a host removing
  # them or the retention worker pruning them waits instead of pulling the
  # row out from under the vote insert. Gone already, they are told so.
  defp lock_participant(poll, participant) do
    case PollParticipantQueries.lock_live(poll.id, participant.id) do
      nil -> {:error, :unknown_participant}
      locked -> {:ok, locked}
    end
  end

  # Confirming lets someone in. On an invite-only poll only the host does
  # that, so a pending request (one inserted just as the host switched the
  # poll, after the switch withdrew the others) cannot confirm itself. Read
  # from the poll locked inside the transaction, fresh.
  defp ensure_admitted(_poll, %PollParticipantSchema{confirmed_at: %DateTime{}}), do: :ok
  defp ensure_admitted(%PollSchema{invite_only: true}, _unconfirmed), do: {:error, :invite_only}
  defp ensure_admitted(%PollSchema{}, _unconfirmed), do: :ok

  defp refuse_if_invite_only(poll_id) do
    if PollQueries.invite_only?(poll_id), do: {:error, :invite_only}, else: :ok
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

  # Only a participant invited without a name lacks one, and they give it with
  # their first responses. Anyone else's name stays as it is.
  defp ensure_named(%PollParticipantSchema{name: nil} = participant, name) do
    participant
    |> PollParticipantSchema.name_changeset(name)
    |> PollParticipantQueries.update()
  end

  defp ensure_named(participant, _name), do: {:ok, participant}

  # One receipt, for the first responses saved. Later changes are saved
  # silently: the receipt already holds the link to come back with.
  defp maybe_send_receipt(%PollParticipantSchema{voted_at: nil}, stamped),
    do: EmailScheduler.schedule_poll_vote_receipt(stamped)

  defp maybe_send_receipt(_participant, _stamped), do: :ok

  defp stamp_voted(participant) do
    participant
    |> PollParticipantSchema.voted_changeset(DateTime.utc_now())
    |> PollParticipantQueries.update()
  end

  # A host who asked to hear about new votes gets them bundled: this joins the
  # update already waiting, or schedules one.
  defp maybe_update_host(%PollSchema{notify_on_vote: true} = poll),
    do: EmailScheduler.schedule_poll_vote_digest(poll)

  defp maybe_update_host(_poll), do: :ok

  @doc """
  Schedules the host's "everyone has voted" nudge once nobody on `poll`
  owes a vote any more. Only a poll the host invited people to knows who
  everyone is: on a poll shared only by its link, "everyone" would be
  whoever happened to ask for a link so far, often just the first voter.

  Reads the database rather than `poll`, so it sees the write that prompted
  it: a vote just saved, or someone the host just took off the poll. The
  nudge is keyed to go out once per round of invitations, so people the host
  invites later, once they have all voted, are reported as well.
  """
  @spec notify_host_if_all_voted(PollSchema.t()) :: :ok
  def notify_host_if_all_voted(poll) do
    if all_participants_voted?(poll) do
      EmailScheduler.schedule_poll_all_voted_nudge(
        poll,
        PollParticipantQueries.invitation_round(poll.id)
      )
    end

    :ok
  end

  defp all_participants_voted?(poll) do
    PollParticipantQueries.any_invited?(poll.id) and
      not PollParticipantQueries.awaiting_votes?(poll.id)
  end
end
