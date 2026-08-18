defmodule Tymeslot.Profiles.BookingPagePublishedAtBackfillTest do
  @moduledoc """
  Verifies `20260629084457_backfill_booking_page_published_at` stamps exactly
  the booking pages that were already live (username + active meeting type)
  and leaves everything else untouched.

  The migration module is loaded from `priv` and run through `Ecto.Migrator`;
  see `Tymeslot.Test.MigrationRunner`.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :profiles
  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_629_084_457

  test "stamps live pages to their earliest active meeting type and skips the rest" do
    # Live: username + two active meeting types — should stamp to the EARLIEST.
    live_user = insert(:user)
    insert(:profile, user: live_user, username: "host", booking_page_published_at: nil)
    earliest = ~N[2026-05-01 09:00:00]

    insert(:meeting_type,
      user: live_user,
      is_active: true,
      inserted_at: ~N[2026-06-10 12:00:00]
    )

    insert(:meeting_type, user: live_user, is_active: true, inserted_at: earliest)

    # Has a username but only an INACTIVE meeting type — not live.
    inactive_user = insert(:user)

    insert(:profile,
      user: inactive_user,
      username: "inactivehost",
      booking_page_published_at: nil
    )

    insert(:meeting_type, user: inactive_user, is_active: false)

    # Active meeting type but NO username — not live.
    nameless_user = insert(:user)
    insert(:profile, user: nameless_user, username: nil, booking_page_published_at: nil)
    insert(:meeting_type, user: nameless_user, is_active: true)

    # Already published — must not be overwritten.
    already = ~U[2026-01-01 00:00:00Z]
    published_user = insert(:user)

    published_profile =
      insert(:profile,
        user: published_user,
        username: "publishedhost",
        booking_page_published_at: already
      )

    insert(:meeting_type, user: published_user, is_active: true)

    # `down/0` is a deliberate no-op and `up/0` only touches NULL rows, so the
    # version is dropped from the ledger and the migration re-applied.
    MigrationRunner.replay!(@version)

    assert DateTime.to_naive(profile_for(live_user).booking_page_published_at) == earliest
    refute profile_for(inactive_user).booking_page_published_at
    refute profile_for(nameless_user).booking_page_published_at
    assert Repo.reload!(published_profile).booking_page_published_at == already
  end

  defp profile_for(user) do
    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    profile
  end
end
