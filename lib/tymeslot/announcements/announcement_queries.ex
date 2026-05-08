defmodule Tymeslot.Announcements.AnnouncementQueries do
  @moduledoc """
  Repo-level queries for the announcements domain.
  Per `CLAUDE.md`, all `Repo.*` calls (other than `transaction`/`rollback`/`preload`)
  live here rather than in the context module.
  """
  import Ecto.Query

  alias Tymeslot.Announcements.UserSeenAnnouncementSchema
  alias Tymeslot.Repo

  @spec seen_keys_for(integer()) :: [String.t()]
  def seen_keys_for(user_id) when is_integer(user_id) do
    UserSeenAnnouncementSchema
    |> where([s], s.user_id == ^user_id)
    |> select([s], s.announcement_key)
    |> Repo.all()
  end

  @spec mark_seen!(integer(), String.t()) :: :ok
  def mark_seen!(user_id, announcement_key)
      when is_integer(user_id) and is_binary(announcement_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %UserSeenAnnouncementSchema{}
    |> UserSeenAnnouncementSchema.changeset(%{
      user_id: user_id,
      announcement_key: announcement_key,
      seen_at: now
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:user_id, :announcement_key])

    :ok
  end
end
