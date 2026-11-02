defmodule Tymeslot.BookingPages.MeetingTypeAddressTest do
  @moduledoc """
  `/<username>/<x>` is one of the host's booking pages or one of their meeting
  types, never both: the meeting type side of the check, whose page side is in
  `Tymeslot.BookingPagesTest`.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types
  @moduletag :profiles

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo

  @clash "is already the address of one of your booking pages"

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern")
    page = insert(:booking_page, profile: profile, slug: "coaching")
    %{user: user, profile: profile, page: page}
  end

  defp attrs(user, extra),
    do: Map.merge(%{name: "Intro", duration_minutes: 30, user_id: user.id}, extra)

  describe "creating a meeting type" do
    test "whose name gives a page's slug is refused on the name", %{user: user} do
      assert {:error, changeset} =
               MeetingTypes.create_meeting_type(attrs(user, %{name: "Coaching"}))

      assert {@clash, _opts} = changeset.errors[:name]
      assert MeetingTypes.get_all_meeting_types(user.id) == []
    end

    test "whose custom slug is a page's is refused on the slug", %{user: user} do
      assert {:error, changeset} =
               MeetingTypes.create_meeting_type(attrs(user, %{slug: "coaching"}))

      assert {@clash, _opts} = changeset.errors[:slug]
    end

    test "with another host's page slug goes ahead", %{user: user} do
      insert(:booking_page, slug: "mentoring")

      assert {:ok, _type} = MeetingTypes.create_meeting_type(attrs(user, %{name: "Mentoring"}))
    end

    test "for a user with no profile goes ahead" do
      user = insert(:user)

      assert {:ok, _type} = MeetingTypes.create_meeting_type(attrs(user, %{name: "Coaching"}))
    end

    test "on a former page address takes it, ending the redirect", %{
      user: user,
      profile: profile,
      page: page
    } do
      {:ok, _page} = BookingPages.update_details(page, %{"slug" => "coaching-pages"})
      assert {:moved, "coaching-pages"} = BookingPages.locate(profile, "coaching")

      assert {:ok, _type} = MeetingTypes.create_meeting_type(attrs(user, %{name: "Coaching"}))

      assert BookingPages.locate(profile, "coaching") == :error
    end
  end

  describe "updating a meeting type" do
    test "renamed to a page's slug is refused", %{user: user} do
      type = insert(:meeting_type, user: user, name: "Intro")

      assert {:error, changeset} = MeetingTypes.update_meeting_type(type, %{name: "Coaching"})
      assert {@clash, _opts} = changeset.errors[:name]
      assert Repo.reload!(type).name == "Intro"
    end

    test "keeping its slug is never a clash", %{user: user} do
      # As a race between the two checks would have left it.
      type = insert(:meeting_type, user: user, name: "Coaching")

      assert {:ok, %{description: "Still here"}} =
               MeetingTypes.update_meeting_type(type, %{description: "Still here"})
    end

    test "given a page's slug as its link is refused as taken", %{user: user} do
      type = insert(:meeting_type, user: user, name: "Intro")

      assert {:error, :slug_taken} = MeetingTypes.update_slug(type, "Coaching")
      assert Repo.reload!(type).slug == nil
    end

    test "cleared back to a name-derived slug that is a page's is refused", %{user: user} do
      type = insert(:meeting_type, user: user, name: "Coaching", slug: "coaching-call")

      assert {:error, :slug_taken} = MeetingTypes.update_slug(type, nil)
      assert Repo.reload!(type).slug == "coaching-call"
    end

    test "given a free slug goes ahead", %{user: user} do
      type = insert(:meeting_type, user: user, name: "Intro")

      assert {:ok, %{slug: "free-link"}} = MeetingTypes.update_slug(type, "free-link")
    end
  end

  test "a custom slug may not be a path routed beneath a type", %{user: user} do
    for slug <- ["book", "thank-you"] do
      assert {:error, changeset} = MeetingTypes.create_meeting_type(attrs(user, %{slug: slug}))
      assert {"is reserved", _opts} = changeset.errors[:slug]
    end
  end
end
