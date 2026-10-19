defmodule Tymeslot.Integrations.Video.RoomCreationErrorQueries do
  @moduledoc """
  Database queries for the room creation error a video integration's provider
  answers with (`Tymeslot.Integrations.Video.RoomCreationError`): the error
  recorded on the integration, and the claims on the email telling its owner.
  """

  import Ecto.Query
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  @doc """
  Records that the provider refuses to create rooms for the integration `id`
  with `code`, stamping the time only when the code is new, so the time stays
  the one the refusal was first seen.
  """
  @spec record(integer(), atom()) :: :ok
  def record(id, code) when is_integer(id) and is_atom(code) do
    VideoIntegrationSchema
    |> where([v], v.id == ^id)
    |> where([v], is_nil(v.room_creation_error) or v.room_creation_error != ^code)
    |> Repo.update_all(
      set: [room_creation_error: code, room_creation_error_since: DateTime.utc_now(:second)]
    )

    :ok
  end

  @doc """
  Clears the room creation error recorded for the integration `id`.
  """
  @spec clear(integer()) :: :ok
  def clear(id) when is_integer(id) do
    VideoIntegrationSchema
    |> where([v], v.id == ^id and not is_nil(v.room_creation_error))
    |> Repo.update_all(set: [room_creation_error: nil, room_creation_error_since: nil])

    :ok
  end

  @doc """
  Claims the email about room creation error `code` for the integration `id`,
  stamping `now` as the time the owner was told: returns `true` for the caller
  that claims it, and `false` while a claim made since `resend_after` stands.

  One conditional update, so concurrent callers serialise on the row and only
  the first one's condition still holds. `release_notice/2`
  gives a claim back when its email never went out.
  """
  @spec claim_notice(integer(), atom(), DateTime.t(), DateTime.t()) ::
          boolean()
  def claim_notice(id, code, now, resend_after)
      when is_integer(id) and is_atom(code) do
    code = Atom.to_string(code)

    {count, _rows} =
      VideoIntegrationSchema
      |> where([v], v.id == ^id)
      |> where(
        [v],
        fragment(
          "? -> ? IS NULL OR (? ->> ?)::timestamptz < ?::timestamptz",
          v.room_creation_error_notices,
          type(^code, :string),
          v.room_creation_error_notices,
          type(^code, :string),
          type(^DateTime.to_iso8601(resend_after), :string)
        )
      )
      |> update([v],
        set: [
          room_creation_error_notices:
            fragment(
              "jsonb_set(coalesce(?, '{}'::jsonb), array[?], to_jsonb(?::text))",
              v.room_creation_error_notices,
              type(^code, :string),
              type(^DateTime.to_iso8601(now), :string)
            )
        ]
      )
      |> Repo.update_all([])

    count == 1
  end

  @doc """
  Gives back the claim on the email about `code` for the integration `id`, for
  an email that was never sent: the next refusal with that code claims it
  again.
  """
  @spec release_notice(integer(), atom()) :: :ok
  def release_notice(id, code) when is_integer(id) and is_atom(code) do
    code = Atom.to_string(code)

    VideoIntegrationSchema
    |> where([v], v.id == ^id)
    |> update([v],
      set: [
        room_creation_error_notices:
          fragment("? - ?", v.room_creation_error_notices, type(^code, :string))
      ]
    )
    |> Repo.update_all([])

    :ok
  end
end
