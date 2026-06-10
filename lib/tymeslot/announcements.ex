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

  @docs_base_url_default "https://tymeslot.app/docs"

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
    * the user signed up before it was published — **or** the user is an admin,
      who bypasses the signup-date gate so they can review what users see.
      Admins still respect the seen and expiry filters, so they see each
      announcement exactly once.
  """
  @spec list_for(UserSchema.t()) :: [Announcement.t()]
  def list_for(%UserSchema{} = user) do
    user_inserted_at = to_utc_datetime(user.inserted_at)
    now = DateTime.utc_now()

    # Evaluate the in-memory catalog first (expiry + signup/admin
    # visibility) — these checks need no database access. Only if some
    # candidate survives do we pay for the per-user seen-keys query. Once
    # every catalogue entry has expired this short-circuits, so a mount can
    # no longer trigger a guaranteed-empty `user_seen_announcements` read.
    candidates =
      catalogs()
      |> Enum.flat_map(&safe_list/1)
      |> Enum.reject(&expired?(&1, now))
      |> Enum.filter(&visible_to?(&1, user, user_inserted_at))

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

  The base is the operator-configurable `:docs_base_url`, defaulting to the
  canonical public docs. Keeping the default in config (rather than hardcoded
  in the catalogue) keeps Core's code free of the SaaS marketing domain.
  """
  @spec docs_url(String.t()) :: String.t()
  def docs_url(slug) when is_binary(slug) do
    base = Application.get_env(:tymeslot, :docs_base_url, @docs_base_url_default)
    "#{String.trim_trailing(base, "/")}/#{slug}"
  end

  defp expired?(%Announcement{expires_at: nil}, _now), do: false

  defp expired?(%Announcement{expires_at: expires_at}, now),
    do: not DateTime.after?(expires_at, now)

  defp visible_to?(_announcement, %UserSchema{is_admin: true}, _user_inserted_at), do: true

  defp visible_to?(%Announcement{published_at: published_at}, _user, user_inserted_at),
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
