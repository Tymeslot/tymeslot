defmodule Tymeslot.Invitations.InvitationQueries do
  @moduledoc "Data access for invitation links."

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Invitations.InvitationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  @spec insert(Changeset.t()) :: {:ok, InvitationSchema.t()} | {:error, Changeset.t()}
  def insert(%Changeset{} = changeset), do: Repo.insert(changeset)

  @spec update(Changeset.t()) :: {:ok, InvitationSchema.t()} | {:error, Changeset.t()}
  def update(%Changeset{} = changeset), do: Repo.update(changeset)

  @spec get(pos_integer()) :: InvitationSchema.t() | nil
  def get(id) do
    InvitationSchema
    |> where([i], i.id == ^id)
    |> preload(:meeting_type)
    |> Repo.one()
  end

  @spec get_for_user(pos_integer(), pos_integer()) :: InvitationSchema.t() | nil
  def get_for_user(user_id, id) do
    Repo.one(from(i in InvitationSchema, where: i.id == ^id and i.user_id == ^user_id))
  end

  @spec get_by_token_hash(String.t()) :: InvitationSchema.t() | nil
  def get_by_token_hash(hash) do
    InvitationSchema
    |> where([i], i.token_hash == ^hash)
    |> preload(:meeting_type)
    |> Repo.one()
  end

  @doc """
  A host's invitations for one meeting type, newest first, with their meetings
  (newest first). `limit:` keeps only the newest that many.
  """
  @spec list_for_meeting_type(pos_integer(), pos_integer(), limit: pos_integer()) ::
          [InvitationSchema.t()]
  def list_for_meeting_type(user_id, meeting_type_id, opts \\ []) do
    meetings = from(m in MeetingSchema, order_by: [desc: m.inserted_at, desc: m.id])

    InvitationSchema
    |> where([i], i.user_id == ^user_id and i.meeting_type_id == ^meeting_type_id)
    |> order_by([i], desc: i.inserted_at, desc: i.id)
    |> limit_to(opts[:limit])
    |> preload(meetings: ^meetings)
    |> Repo.all()
  end

  defp limit_to(query, nil), do: query
  defp limit_to(query, limit), do: limit(query, ^limit)
end
