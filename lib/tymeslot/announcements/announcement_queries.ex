defmodule Tymeslot.Announcements.AnnouncementQueries do
  @moduledoc """
  Repo-level queries for the announcements domain.
  Per `CLAUDE.md`, all `Repo.*` calls (other than `transaction`/`rollback`/`preload`)
  live here rather than in the context module.
  """
  import Ecto.Query

  require Logger

  alias Tymeslot.Announcements.UserSeenAnnouncementSchema
  alias Tymeslot.Repo

  @spec seen_keys_for(integer()) :: [String.t()]
  def seen_keys_for(user_id) when is_integer(user_id) do
    UserSeenAnnouncementSchema
    |> where([s], s.user_id == ^user_id)
    |> select([s], s.announcement_key)
    |> Repo.all()
  end

  @doc """
  Records that a user has seen an announcement. Always returns `:ok`.

  Marking-seen is a best-effort, non-critical side effect driven by a
  dashboard modal interaction (Next/Close/CTA). It must never crash the
  caller's LiveView, so every failure is swallowed and logged:

    * a duplicate `(user_id, announcement_key)` is a no-op via
      `on_conflict: :nothing`;
    * an FK violation (user deleted concurrently) or any other DB error is
      caught and logged rather than raised.
  """
  @spec mark_seen!(integer(), String.t()) :: :ok
  def mark_seen!(user_id, announcement_key)
      when is_integer(user_id) and is_binary(announcement_key) do
    now = DateTime.utc_now(:second)

    changeset =
      UserSeenAnnouncementSchema.changeset(%UserSeenAnnouncementSchema{}, %{
        user_id: user_id,
        announcement_key: announcement_key,
        seen_at: now
      })

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:user_id, :announcement_key]
         ) do
      {:ok, _record} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to mark announcement seen; ignoring.",
          user_id: user_id,
          announcement_key: announcement_key,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  rescue
    error ->
      # A raw constraint error (e.g. FK violation under a race) surfaces as
      # an exception rather than a changeset error. Treat it the same way:
      # marking-seen is non-critical and must not crash the dashboard.
      Logger.warning("Marking announcement seen raised; ignoring.",
        user_id: user_id,
        announcement_key: announcement_key,
        error: Exception.message(error)
      )

      :ok
  end
end
