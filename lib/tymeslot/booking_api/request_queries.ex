defmodule Tymeslot.BookingApi.RequestQueries do
  @moduledoc """
  Database queries for booking API idempotency claims.
  """

  import Ecto.Query

  alias Tymeslot.BookingApi.RequestSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  @doc """
  Claims `idempotency_key` for an organiser.

  Returns `{:error, :already_claimed}` when the key is taken, whether by a
  finished request or by one still in flight — the unique index is what makes
  two concurrent retries of the same request resolve to a single booking.
  """
  @spec claim(integer(), String.t()) ::
          {:ok, RequestSchema.t()} | {:error, :already_claimed | Ecto.Changeset.t()}
  def claim(user_id, idempotency_key) do
    changeset =
      RequestSchema.claim_changeset(%{user_id: user_id, idempotency_key: idempotency_key})

    case Repo.insert(changeset) do
      {:ok, request} -> {:ok, request}
      {:error, failed} -> classify(failed)
    end
  end

  @doc "Records the meeting a claimed key produced."
  @spec attach_meeting(RequestSchema.t(), Ecto.UUID.t()) ::
          {:ok, RequestSchema.t()} | {:error, Ecto.Changeset.t()}
  def attach_meeting(%RequestSchema{} = request, meeting_id) do
    request
    |> RequestSchema.meeting_changeset(meeting_id)
    |> Repo.update()
  end

  @doc """
  Releases a claim whose booking never happened, freeing the key for a retry.
  """
  @spec release(RequestSchema.t()) :: {:ok, RequestSchema.t()} | {:error, Ecto.Changeset.t()}
  def release(%RequestSchema{} = request), do: Repo.delete(request)

  @doc """
  Returns the meeting an organiser's key produced.

  `{:error, :not_found}` covers both an unknown key and one that is claimed but
  whose booking has not finished; the caller distinguishes them by having just
  been refused the claim.
  """
  @spec get_meeting(integer(), String.t()) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def get_meeting(user_id, idempotency_key) do
    query =
      from(request in RequestSchema,
        join: meeting in MeetingSchema,
        on: meeting.id == request.meeting_id,
        where: request.user_id == ^user_id and request.idempotency_key == ^idempotency_key,
        select: meeting
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  defp classify(%Ecto.Changeset{errors: errors} = changeset) do
    if unique_violation?(errors[:idempotency_key]) do
      {:error, :already_claimed}
    else
      {:error, changeset}
    end
  end

  defp unique_violation?({_message, opts}), do: Keyword.get(opts, :constraint) == :unique
  defp unique_violation?(_other), do: false
end
