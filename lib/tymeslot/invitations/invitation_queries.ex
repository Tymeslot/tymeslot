defmodule Tymeslot.Invitations.InvitationQueries do
  @moduledoc "Data access for invitation links."

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Invitations.{InvitationSchema, InvitationStatus}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  @spec insert(Changeset.t()) :: {:ok, InvitationSchema.t()} | {:error, Changeset.t()}
  def insert(%Changeset{} = changeset), do: Repo.insert(changeset)

  @spec update(Changeset.t()) :: {:ok, InvitationSchema.t()} | {:error, Changeset.t()}
  def update(%Changeset{} = changeset), do: Repo.update(changeset)

  @spec get(pos_integer()) :: InvitationSchema.t() | nil
  def get(id), do: Repo.get(InvitationSchema, id)

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

  @doc "A host's invitations for one meeting type, newest first, with their meetings (newest first)."
  @spec list_for_meeting_type(pos_integer(), pos_integer()) :: [InvitationSchema.t()]
  def list_for_meeting_type(user_id, meeting_type_id) do
    meetings = from(m in MeetingSchema, order_by: [desc: m.inserted_at, desc: m.id])

    InvitationSchema
    |> where([i], i.user_id == ^user_id and i.meeting_type_id == ^meeting_type_id)
    |> order_by([i], desc: i.inserted_at, desc: i.id)
    |> preload(meetings: ^meetings)
    |> Repo.all()
  end

  @doc "The meeting using the invitation up, if any (most recent first)."
  @spec consuming_meeting(InvitationSchema.t()) :: MeetingSchema.t() | nil
  def consuming_meeting(%InvitationSchema{id: id} = invitation) do
    MeetingSchema
    |> where([m], m.invitation_id == ^id)
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> Repo.all()
    |> Enum.find(&InvitationStatus.consumes?(invitation, &1))
  end
end
