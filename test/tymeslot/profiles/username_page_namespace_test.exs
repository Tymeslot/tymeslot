defmodule Tymeslot.Profiles.UsernamePageNamespaceTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  test "a page's address is not available as a username" do
    insert(:booking_page, slug: "einfachiso")

    refute Profiles.username_available?("einfachiso")
    refute Profiles.username_available?("EinfachISO")
    assert Profiles.username_status(insert(:profile), "einfachiso") == :taken
  end

  test "writing a username a page holds is refused as taken, without the screen's check" do
    insert(:booking_page, slug: "einfachiso")
    profile = insert(:profile, username: "sarah")

    assert {:error, changeset} = Profiles.change_username(profile, "einfachiso")
    assert Profiles.username_error(changeset) == :taken
    assert Repo.reload!(profile).username == "sarah"
  end

  test "a page cannot be renamed onto a username" do
    insert(:profile, username: "sarah")
    page = insert(:booking_page, slug: "coaching")

    assert {:error, changeset} = BookingPages.update_details(page, %{slug: "sarah"})
    assert {"has already been taken", _opts} = changeset.errors[:slug]
    assert Repo.reload!(page).slug == "coaching"
  end

  test "an address no page or profile holds is available" do
    assert Profiles.username_available?("nobody-has-this")
  end
end
