defmodule Tymeslot.Invitations do
  @moduledoc """
  Single-use invitation links for invitation-only meeting types.

  A link books one appointment. It is used up only once a booking holds it
  (see `Tymeslot.Invitations.InvitationStatus`), can expire or be revoked, and
  its status is always derived from its meetings. Revoking stops new bookings
  only; it never cancels one.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  alias Tymeslot.Clock
  alias Tymeslot.Invitations.{InvitationQueries, InvitationSchema, InvitationStatus}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.Token

  # The links' tokens, kept encrypted so the host can be shown a link again.
  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage,
    do: {InvitationSchema.__schema__(:source), EncryptedString.columns(InvitationSchema)}

  @type entry :: %{
          invitation: InvitationSchema.t(),
          status: InvitationStatus.status(),
          meeting: MeetingSchema.t() | nil
        }

  @doc """
  Creates an invitation for one of the host's invitation-only types. The
  returned struct carries the plaintext token, which is not recoverable from
  the database except through the encrypted column.
  """
  @spec create(pos_integer(), MeetingTypeSchema.t(), map()) ::
          {:ok, InvitationSchema.t()}
          | {:error, :rate_limited, String.t()}
          | {:error, :not_invitation_only}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
  def create(user_id, %MeetingTypeSchema{user_id: owner_id}, _attrs) when owner_id != user_id,
    do: {:error, :not_found}

  def create(_user_id, %MeetingTypeSchema{invitation_only: false}, _attrs),
    do: {:error, :not_invitation_only}

  def create(user_id, %MeetingTypeSchema{} = meeting_type, attrs) do
    with :ok <- RateLimiter.check(:invitation_create, user_id) do
      %InvitationSchema{meeting_type_id: meeting_type.id, user_id: user_id}
      |> InvitationSchema.creation_changeset(attrs)
      |> InvitationQueries.insert()
    end
  end

  @doc "The host's invitations for a type, newest first, each with its derived status."
  @spec list(pos_integer(), MeetingTypeSchema.t()) :: [entry()]
  def list(user_id, %MeetingTypeSchema{id: meeting_type_id}) do
    now = Clock.utc_now()

    user_id
    |> InvitationQueries.list_for_meeting_type(meeting_type_id)
    |> Enum.map(fn %InvitationSchema{meetings: meetings} = invitation ->
      consuming = Enum.find(meetings, &InvitationStatus.consumes?(invitation, &1))

      %{
        invitation: invitation,
        status: InvitationStatus.status(invitation, consuming, now),
        meeting: consuming || List.first(meetings)
      }
    end)
  end

  @doc "Stops new bookings through the invitation. Repeating it changes nothing."
  @spec revoke(pos_integer(), pos_integer()) :: {:ok, InvitationSchema.t()} | {:error, :not_found}
  def revoke(user_id, id) do
    with_invitation(user_id, id, fn
      %InvitationSchema{revoked_at: nil} = invitation ->
        invitation
        |> InvitationSchema.revoke_changeset(Clock.utc_now())
        |> InvitationQueries.update()

      %InvitationSchema{} = invitation ->
        {:ok, invitation}
    end)
  end

  @doc """
  Makes a used invitation (whose meeting no longer holds a slot) or a revoked
  one bookable again. Meetings booked before the reopen stop counting.
  """
  @spec reopen(pos_integer(), pos_integer()) ::
          {:ok, InvitationSchema.t()} | {:error, :not_found | :not_reopenable}
  def reopen(user_id, id) do
    now = Clock.utc_now()

    with_invitation(user_id, id, fn invitation ->
      consuming = InvitationQueries.consuming_meeting(invitation)

      if InvitationStatus.reopenable?(invitation, consuming) or
           InvitationStatus.status(invitation, consuming, now) == :revoked do
        invitation |> InvitationSchema.reopen_changeset(now) |> InvitationQueries.update()
      else
        {:error, :not_reopenable}
      end
    end)
  end

  @doc """
  Finds the invitation behind a link's token, if the link can be used to book.
  The error says why not, for a page to explain.
  """
  @spec resolve(String.t() | nil) ::
          {:ok, InvitationSchema.t()} | {:error, :not_found | :used | :expired | :revoked}
  def resolve(token) when is_binary(token) do
    with %InvitationSchema{meeting_type: meeting_type} = invitation <-
           token |> Token.hash_token() |> InvitationQueries.get_by_token_hash(),
         true <- meeting_type.is_active and meeting_type.invitation_only do
      case status_of(invitation) do
        :available -> {:ok, invitation}
        reason -> {:error, reason}
      end
    else
      _unknown -> {:error, :not_found}
    end
  end

  def resolve(_token), do: {:error, :not_found}

  @doc """
  Pre-check at booking time: the invitation belongs to the meeting type and is
  still available. The database index, not this, guarantees single use.
  """
  @spec check_claimable(pos_integer(), pos_integer()) :: :ok | {:error, :invitation_unavailable}
  def check_claimable(invitation_id, meeting_type_id) do
    case InvitationQueries.get(invitation_id) do
      %InvitationSchema{meeting_type_id: ^meeting_type_id} = invitation ->
        if status_of(invitation) == :available, do: :ok, else: {:error, :invitation_unavailable}

      _other ->
        {:error, :invitation_unavailable}
    end
  end

  defp status_of(invitation) do
    now = Clock.utc_now()
    InvitationStatus.status(invitation, InvitationQueries.consuming_meeting(invitation), now)
  end

  defp with_invitation(user_id, id, fun) do
    case InvitationQueries.get_for_user(user_id, id) do
      nil -> {:error, :not_found}
      invitation -> fun.(invitation)
    end
  end
end
