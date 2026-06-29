defmodule Tymeslot.Repo.Migrations.BackfillBookingPagePublishedAt do
  use Ecto.Migration

  @moduledoc """
  Stamps `booking_page_published_at` for booking pages that were already live
  before the column existed (and before the publish stamp was wired into every
  go-live path). A page is live once the host has a username and at least one
  active meeting type; until this backfill those historical pages read as
  unpublished, undercounting the onboarding `:page_published` milestone and the
  `booking_page_published` analytics event.

  The published moment is approximated by the host's earliest active meeting
  type (`MIN(inserted_at)`) — the closest historical signal available, since no
  username-set timestamp is recorded.

  Idempotent: only rows still NULL are touched, so it is safe to re-run.
  """

  def up do
    execute("""
    UPDATE profiles p
    SET booking_page_published_at = sub.first_active_mt
    FROM (
      SELECT mt.user_id, MIN(mt.inserted_at)::timestamp(0) AS first_active_mt
      FROM meeting_types mt
      WHERE mt.is_active = true
      GROUP BY mt.user_id
    ) sub
    WHERE p.user_id = sub.user_id
      AND p.username IS NOT NULL
      AND p.username <> ''
      AND p.booking_page_published_at IS NULL
    """)
  end

  # The stamp is a derived historical fact, not reversible state — there is no
  # safe way to know which rows this backfill set, so the down migration is a
  # no-op rather than blindly clearing the column.
  def down, do: :ok
end
