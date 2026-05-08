defmodule Tymeslot.Announcements do
  @moduledoc """
  Public API for the feature-announcement domain.

  Announcements are static, code-defined entries (see `Tymeslot.Announcements.Catalog`).
  Per-user seen state lives in the `user_seen_announcements` table.

  See `docs/superpowers/specs/2026-05-08-feature-announcement-modal-design.md`.
  """

  require Logger

  alias Tymeslot.Announcements.Announcement
  alias Tymeslot.Announcements.AnnouncementQueries
  alias Tymeslot.Auth.UserSchema

  @spec mark_seen!(UserSchema.t(), String.t()) :: :ok
  def mark_seen!(%UserSchema{id: user_id}, announcement_key)
      when is_binary(announcement_key) do
    AnnouncementQueries.mark_seen!(user_id, announcement_key)
  end

  @spec list_for(UserSchema.t()) :: [Announcement.t()]
  def list_for(%UserSchema{} = user) do
    seen = MapSet.new(AnnouncementQueries.seen_keys_for(user.id))
    user_inserted_at = to_utc_datetime(user.inserted_at)

    catalogs()
    |> Enum.flat_map(&safe_list/1)
    |> Enum.reject(&MapSet.member?(seen, &1.key))
    |> Enum.filter(&DateTime.after?(&1.published_at, user_inserted_at))
    |> Enum.sort_by(& &1.published_at, DateTime)
  end

  defp catalogs do
    Application.get_env(:tymeslot, :announcement_catalogs, [])
  end

  defp safe_list(catalog) do
    catalog.list()
  rescue
    e ->
      Logger.warning("Announcement catalog failed to load; skipping.",
        module: catalog,
        error: Exception.message(e)
      )

      []
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
end
