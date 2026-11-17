defmodule Tymeslot.Migrations.MoveBookingPagesOffSeriesSlugTest do
  @moduledoc """
  Value-correctness regression for
  `20261117080221_move_booking_pages_off_series_slug`, which moves any booking
  page at the newly reserved `series` slug to a free one.

  The decisive properties are that the page ends at an address nothing else
  of its profile holds, and that `/<username>/series` keeps leading to it
  through a redirect.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :profiles

  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageRedirectQueries
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_117_080_221

  defp insert_redirect(profile, slug, page_id),
    do: :ok = BookingPageRedirectQueries.put(profile.id, slug, page_id)

  defp slug_of(page), do: Repo.get!(BookingPageSchema, page.id).slug

  test "a page at series moves to series-page and its old address leads to it" do
    page = insert(:booking_page, slug: "series")
    profile = page.profile

    MigrationRunner.replay!(@version)

    assert slug_of(page) == "series-page"
    assert BookingPages.locate(profile, "series") == {:moved, "series-page"}
  end

  test "skips every candidate the profile already holds in any form" do
    page = insert(:booking_page, slug: "series")
    profile = page.profile

    insert(:booking_page, profile: profile, slug: "series-page")
    insert_redirect(profile, "series-page-2", nil)
    insert(:meeting_type, user: profile.user, name: "Series Page 3", slug: nil)
    insert(:meeting_type, user: profile.user, slug: "series-page-4")

    MigrationRunner.replay!(@version)

    assert slug_of(page) == "series-page-5"
  end

  test "another profile's addresses do not count against the page" do
    page = insert(:booking_page, slug: "series")
    insert(:booking_page, slug: "series-page")

    MigrationRunner.replay!(@version)

    assert slug_of(page) == "series-page"
  end

  test "an existing redirect at series is pointed at the moved page" do
    page = insert(:booking_page, slug: "series")
    profile = page.profile
    insert_redirect(profile, "series", nil)

    MigrationRunner.replay!(@version)

    assert BookingPages.locate(profile, "series") == {:moved, "series-page"}
  end

  test "leaves other pages alone and is safe to run again" do
    page = insert(:booking_page, slug: "series")
    other = insert(:booking_page, slug: "series-of-talks")

    MigrationRunner.replay!(@version)
    MigrationRunner.replay!(@version)

    assert slug_of(page) == "series-page"
    assert slug_of(other) == "series-of-talks"
  end
end
