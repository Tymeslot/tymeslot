defmodule Tymeslot.BookingPagesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  import ExUnit.CaptureLog
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "2")
    %{user: user, profile: profile}
  end

  describe "create/2" do
    test "creates a page on the profile's theme with its colours copied", %{profile: profile} do
      insert(:theme_customization, profile: profile, theme_id: "2", color_scheme: "ocean")

      assert {:ok, page} =
               BookingPages.create(profile, %{"name" => "einfachISO", "slug" => " EinfachISO "})

      assert page.slug == "einfachiso"
      assert page.booking_theme == "2"
      assert page.booking_text_enabled == false

      assert %{color_scheme: "ocean"} =
               ThemeCustomizations.get_by_profile_and_theme({profile.id, page.id}, "2")
    end

    # A row saved under rules since tightened (a retired scheme, preset or
    # theme) cannot be copied as it is; the page starts without it.
    test "skips a colour row the current rules reject and copies the rest", %{profile: profile} do
      insert(:theme_customization, profile: profile, theme_id: "2", color_scheme: "ocean")
      insert(:theme_customization, profile: profile, theme_id: "1", color_scheme: "no-such")

      {result, log} =
        with_log(fn ->
          BookingPages.create(profile, %{"name" => "einfachISO", "slug" => "einfachiso"})
        end)

      assert {:ok, page} = result

      assert %{color_scheme: "ocean"} =
               ThemeCustomizations.get_by_profile_and_theme({profile.id, page.id}, "2")

      refute ThemeCustomizations.get_by_profile_and_theme({profile.id, page.id}, "1")
      assert log =~ "Skipped a colour row"
      assert log =~ "color_scheme"
    end

    test "refuses an address that is a username", %{profile: profile} do
      insert(:profile, username: "taken-name")

      assert {:error, changeset} =
               BookingPages.create(profile, %{"name" => "X", "slug" => "Taken-Name"})

      assert {"has already been taken", _opts} = changeset.errors[:slug]
    end

    test "refuses an address another page holds, whatever its case", %{profile: profile} do
      insert(:booking_page, slug: "einfachiso")

      assert {:error, changeset} =
               BookingPages.create(profile, %{"name" => "X", "slug" => "EINFACHISO"})

      assert {"has already been taken", _opts} = changeset.errors[:slug]
    end

    test "stops at the cap", %{profile: profile} do
      for n <- 1..BookingPages.max_pages() do
        insert(:booking_page, profile: profile, slug: "cap-page-#{n}")
      end

      assert {:error, :limit_reached} =
               BookingPages.create(profile, %{"name" => "One more", "slug" => "one-more"})
    end
  end

  describe "update_details/2" do
    test "keeping its own address is not a clash", %{profile: profile} do
      page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "Old")

      assert {:ok, %{name: "New", slug: "einfachiso"}} =
               BookingPages.update_details(page, %{"name" => "New", "slug" => "einfachiso"})
    end

    test "moving to a username's address is refused", %{profile: profile} do
      page = insert(:booking_page, profile: profile, slug: "einfachiso")

      assert {:error, changeset} =
               BookingPages.update_details(page, %{"name" => "X", "slug" => "joern"})

      assert {"has already been taken", _opts} = changeset.errors[:slug]
    end

    test "a page deleted meanwhile is not found, not a crash", %{profile: profile} do
      page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "Old")
      {:ok, _deleted} = BookingPages.delete(page)

      assert {:error, :not_found} = BookingPages.update_details(page, %{"name" => "New"})
    end

    # An emptied field casts to nil, which the trimming must let through to
    # the required check.
    test "an emptied name or address can't be blank, in the form and on save", %{
      profile: profile
    } do
      page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "Old")

      for {field, attrs} <- [
            name: %{"name" => "", "slug" => "einfachiso"},
            slug: %{"name" => "Old", "slug" => " "}
          ] do
        assert {"can't be blank", _opts} = BookingPages.change_details(page, attrs).errors[field]
        assert {:error, changeset} = BookingPages.update_details(page, attrs)
        assert {"can't be blank", _opts} = changeset.errors[field]
      end

      assert %{name: "Old", slug: "einfachiso"} = Repo.reload!(page)
    end
  end

  test "update_theme/2 changes only the page", %{profile: profile} do
    page = insert(:booking_page, profile: profile, booking_theme: "2")

    assert {:ok, %{booking_theme: "1"}} = BookingPages.update_theme(page, "1")
    assert Repo.reload!(profile).booking_theme == "2"
  end

  test "update_booking_text/2 applies the profile's rules", %{profile: profile} do
    page = insert(:booking_page, profile: profile)

    assert {:error, changeset} =
             BookingPages.update_booking_text(page, %{"booking_text_enabled" => "true"})

    assert changeset.errors[:booking_heading]

    assert {:ok, page} =
             BookingPages.update_booking_text(page, %{
               "booking_text_enabled" => "true",
               "booking_heading" => "  Consulting  ",
               "booking_greeting" => "Hi",
               "booking_instruction" => "Pick one"
             })

    assert page.booking_heading == "Consulting"
  end

  test "delete/1 removes the page and its colours, not the profile's", %{profile: profile} do
    page = insert(:booking_page, profile: profile)
    insert(:theme_customization, profile: profile, theme_id: "1")
    insert(:theme_customization, profile: profile, booking_page: page, theme_id: "1")

    assert {:ok, _deleted} = BookingPages.delete(page)
    assert BookingPages.list(profile.id) == []
    assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
  end

  test "delete/1 of a page already deleted, say in another tab, succeeds", %{profile: profile} do
    page = insert(:booking_page, profile: profile)
    {:ok, _deleted} = BookingPages.delete(page)

    assert {:ok, _deleted_again} = BookingPages.delete(page)
  end

  test "fetch/2 only finds the profile's own pages", %{profile: profile} do
    mine = insert(:booking_page, profile: profile)
    theirs = insert(:booking_page)

    assert {:ok, %{id: id}} = BookingPages.fetch(profile.id, to_string(mine.id))
    assert id == mine.id
    assert {:error, :not_found} = BookingPages.fetch(profile.id, theirs.id)
    assert {:error, :not_found} = BookingPages.fetch(profile.id, "nonsense")
  end
end
