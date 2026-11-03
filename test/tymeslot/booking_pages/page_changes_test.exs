defmodule Tymeslot.BookingPages.PageChangesTest do
  @moduledoc """
  What the dashboard reads about a profile's pages beyond the pages
  themselves: the change notices other tabs follow, the meeting types a
  delete would leave unlisted, and each type's one address for a list.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  import Tymeslot.Factory

  alias Tymeslot.BookingPages

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern")
    page = insert(:booking_page, profile: profile, slug: "audits", name: "Audits")
    %{user: user, profile: profile, page: page}
  end

  describe "subscribe/1" do
    setup %{profile: profile} do
      :ok = BookingPages.subscribe(profile.id)
    end

    test "announces a page created, renamed and deleted", %{profile: profile, page: page} do
      profile_id = profile.id

      {:ok, created} = BookingPages.create(profile, %{"name" => "Talks", "slug" => "talks"})
      assert_receive {:booking_pages_changed, ^profile_id}

      {:ok, _renamed} = BookingPages.update_details(created, %{"slug" => "lectures"})
      assert_receive {:booking_pages_changed, ^profile_id}

      {:ok, _deleted} = BookingPages.delete(page)
      assert_receive {:booking_pages_changed, ^profile_id}
    end

    test "announces a meeting type listed on a page", %{user: user, profile: profile, page: page} do
      profile_id = profile.id
      type = insert(:meeting_type, user: user)

      :ok = BookingPages.set_meeting_type(page, type.id, true)
      assert_receive {:booking_pages_changed, ^profile_id}
    end

    test "says nothing about a refused change", %{page: page} do
      assert {:error, _changeset} = BookingPages.update_details(page, %{"slug" => "x"})
      refute_receive {:booking_pages_changed, _profile_id}
    end
  end

  describe "only_listed_on/1" do
    test "names the types no other page and not the main page lists", %{
      user: user,
      profile: profile,
      page: page
    } do
      other = insert(:booking_page, profile: profile, slug: "talks")
      only_here = insert(:meeting_type, user: user, name: "Only here", is_private: true)
      also_other = insert(:meeting_type, user: user, name: "Also other", is_private: true)
      also_main = insert(:meeting_type, user: user, name: "Also main", is_private: false)
      insert(:meeting_type, user: user, name: "Nowhere", is_private: true)

      for type <- [only_here, also_other, also_main],
          do: :ok = BookingPages.set_meeting_type(page, type.id, true)

      :ok = BookingPages.set_meeting_type(other, also_other.id, true)

      assert Enum.map(BookingPages.only_listed_on(page), & &1.name) == ["Only here"]
    end
  end

  describe "meeting_type_paths/2" do
    test "agrees with meeting_type_path/2 for each type", %{
      user: user,
      profile: profile,
      page: page
    } do
      later = insert(:booking_page, profile: profile, slug: "talks")
      on_main = insert(:meeting_type, user: user, slug: "intro", is_private: false)
      on_pages = insert(:meeting_type, user: user, slug: "audit", is_private: true)
      nowhere = insert(:meeting_type, user: user, slug: "secret", is_private: true)

      :ok = BookingPages.set_meeting_type(later, on_pages.id, true)
      :ok = BookingPages.set_meeting_type(page, on_pages.id, true)

      paths = BookingPages.meeting_type_paths(profile, [on_main, on_pages, nowhere])

      assert paths == %{
               on_main.id => "/joern/intro",
               on_pages.id => "/joern/audits/audit",
               nowhere.id => "/joern/secret"
             }

      for type <- [on_main, on_pages, nowhere],
          do: assert(paths[type.id] == BookingPages.meeting_type_path(profile, type))
    end
  end
end
