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
  alias TymeslotWeb.Live.Shared.DocsUrl

  @doc """
  Records that the given user has seen an announcement.

  Best-effort and always returns `:ok`. A `nil` user (e.g. a modal event
  arriving on a socket with no `current_user`) is a no-op rather than a
  crash, and the underlying query swallows DB/constraint errors — this is a
  non-critical dashboard side effect that must never take down the LiveView.
  """
  @spec mark_seen!(UserSchema.t() | nil, String.t()) :: :ok
  def mark_seen!(%UserSchema{id: user_id}, announcement_key)
      when is_binary(announcement_key) do
    AnnouncementQueries.mark_seen!(user_id, announcement_key)
  end

  def mark_seen!(nil, announcement_key) when is_binary(announcement_key), do: :ok

  @doc """
  Returns the unseen, unexpired announcements a user should be shown.

  An announcement is shown when all hold:

    * the user has not already marked it seen;
    * it has not expired (`expires_at` is `nil` or still in the future);
    * the user signed up before it was published.

  Admins are gated by signup date exactly like everyone else — there is no
  bypass.
  """
  @spec list_for(UserSchema.t()) :: [Announcement.t()]
  def list_for(%UserSchema{} = user) do
    user_inserted_at = to_utc_datetime(user.inserted_at)
    now = DateTime.utc_now()

    # Evaluate the in-memory catalog first (expiry + signup-date
    # visibility) — these checks need no database access. Only if some
    # candidate survives do we pay for the per-user seen-keys query. Once
    # every catalogue entry has expired this short-circuits, so a mount can
    # no longer trigger a guaranteed-empty `user_seen_announcements` read.
    candidates =
      catalogs()
      |> Enum.flat_map(&safe_list/1)
      |> Enum.reject(&expired?(&1, now))
      |> Enum.filter(&published_after_signup?(&1, user_inserted_at))

    case candidates do
      [] ->
        []

      candidates ->
        seen = MapSet.new(AnnouncementQueries.seen_keys_for(user.id))

        candidates
        |> Enum.reject(&MapSet.member?(seen, &1.key))
        |> Enum.sort_by(& &1.published_at, DateTime)
    end
  end

  @doc """
  Composes the full documentation URL for a CTA slug.

  Delegates to `TymeslotWeb.Live.Shared.DocsUrl.article_url/1`, the single
  place `:docs_article_base_url` is read and normalised, so an operator
  pointing that setting at their own docs gets announcement CTAs too, not
  just the rest of the dashboard's help links.
  """
  @spec docs_url(String.t()) :: String.t()
  def docs_url(slug) when is_binary(slug), do: DocsUrl.article_url(slug)

  defp expired?(%Announcement{expires_at: nil}, _now), do: false

  defp expired?(%Announcement{expires_at: expires_at}, now),
    do: not DateTime.after?(expires_at, now)

  defp published_after_signup?(%Announcement{published_at: published_at}, user_inserted_at),
    do: DateTime.after?(published_at, user_inserted_at)

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
