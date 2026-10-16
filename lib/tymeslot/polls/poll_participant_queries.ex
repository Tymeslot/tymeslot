defmodule Tymeslot.Polls.PollParticipantQueries do
  @moduledoc """
  Data access for poll participants.

  A participant is confirmed once they have saved responses through the link
  emailed to them, and only confirmed participants count (see
  `Tymeslot.Polls.PollParticipantSchema`). An unconfirmed one whose link was
  last sent before `expiry_cutoff/0` has expired: their link no longer
  resolves and the retention worker deletes the row.
  """

  import Ecto.Query

  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token

  @spec insert(Ecto.Changeset.t()) ::
          {:ok, PollParticipantSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @spec update(Ecto.Changeset.t()) ::
          {:ok, PollParticipantSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset), do: Repo.update(changeset)

  @doc "The participant on `poll_id` under `email`, confirmed or not."
  @spec get_by_poll_and_email(Ecto.UUID.t(), String.t()) :: PollParticipantSchema.t() | nil
  def get_by_poll_and_email(poll_id, email) do
    PollParticipantSchema
    |> where([p], p.poll_id == ^poll_id and p.email == ^email)
    |> preload(:votes)
    |> Repo.one()
  end

  @doc """
  The participant on `poll_id` holding `token`, unless they are unconfirmed and
  their link has expired.
  """
  @spec get_by_poll_and_token(Ecto.UUID.t(), String.t()) :: PollParticipantSchema.t() | nil
  def get_by_poll_and_token(poll_id, token) when is_binary(token) do
    token_hash = Token.hash_token(token)

    PollParticipantSchema
    |> where([p], p.poll_id == ^poll_id and p.token_hash == ^token_hash)
    |> where_live()
    |> preload(:votes)
    |> Repo.one()
  end

  @doc "Fetches a participant by id with their poll, its slots and its host preloaded, for email sending."
  @spec get_with_poll(Ecto.UUID.t()) :: PollParticipantSchema.t() | nil
  def get_with_poll(id) do
    PollParticipantSchema
    |> where([p], p.id == ^id)
    |> preload([:votes, poll: [:time_slots, user: :profile]])
    |> Repo.one()
  end

  @spec count_confirmed(Ecto.UUID.t()) :: non_neg_integer()
  def count_confirmed(poll_id) do
    PollParticipantSchema
    |> where([p], p.poll_id == ^poll_id and not is_nil(p.confirmed_at))
    |> Repo.aggregate(:count)
  end

  @doc "Counts the unconfirmed participants on `poll_id` whose link has not expired."
  @spec count_unconfirmed(Ecto.UUID.t()) :: non_neg_integer()
  def count_unconfirmed(poll_id) do
    PollParticipantSchema
    |> where([p], p.poll_id == ^poll_id and is_nil(p.confirmed_at))
    |> where([p], p.link_sent_at > ^expiry_cutoff())
    |> Repo.aggregate(:count)
  end

  @doc "Confirmed participants on `poll_id` who have not voted."
  @spec list_unvoted_for_poll(Ecto.UUID.t()) :: [PollParticipantSchema.t()]
  def list_unvoted_for_poll(poll_id) do
    PollParticipantSchema
    |> where([p], p.poll_id == ^poll_id and is_nil(p.voted_at))
    |> where([p], not is_nil(p.confirmed_at))
    |> Repo.all()
  end

  @doc """
  Whether anyone on `poll_id` still owes a vote: a confirmed participant who
  has not voted, or someone whose link is out and has not expired.
  """
  @spec awaiting_votes?(Ecto.UUID.t()) :: boolean()
  def awaiting_votes?(poll_id) do
    PollParticipantSchema
    |> where([p], p.poll_id == ^poll_id and is_nil(p.voted_at))
    |> where_live()
    |> Repo.exists?()
  end

  @doc """
  Stamps `link_sent_at` with `now` unless the link was sent after
  `resend_before`. Returns whether it stamped, i.e. whether the caller should
  send the link.
  """
  @spec claim_link_send(Ecto.UUID.t(), DateTime.t(), DateTime.t()) :: boolean()
  def claim_link_send(id, %DateTime{} = now, %DateTime{} = resend_before) do
    {count, _rows} =
      PollParticipantSchema
      |> where([p], p.id == ^id)
      |> where([p], is_nil(p.link_sent_at) or p.link_sent_at <= ^resend_before)
      |> Repo.update_all(set: [link_sent_at: DateTime.truncate(now, :second)])

    count == 1
  end

  @doc "Deletes unconfirmed participants whose link was last sent before `cutoff`."
  @spec delete_expired_unconfirmed(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_expired_unconfirmed(%DateTime{} = cutoff) do
    PollParticipantSchema
    |> where([p], is_nil(p.confirmed_at))
    |> where([p], is_nil(p.link_sent_at) or p.link_sent_at <= ^cutoff)
    |> Repo.delete_all()
  end

  @doc "The moment before which an unconfirmed participant's link has expired."
  @spec expiry_cutoff() :: DateTime.t()
  def expiry_cutoff do
    DateTime.add(DateTime.utc_now(), -PollParticipantSchema.unconfirmed_ttl_seconds(), :second)
  end

  defp where_live(query) do
    cutoff = expiry_cutoff()
    where(query, [p], not is_nil(p.confirmed_at) or p.link_sent_at > ^cutoff)
  end
end
