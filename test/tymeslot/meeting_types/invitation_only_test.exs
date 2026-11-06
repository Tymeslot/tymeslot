defmodule Tymeslot.MeetingTypes.InvitationOnlyTest do
  @moduledoc """
  Invitation-only meeting types: one-to-one only, and hidden from every
  public listing.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types
  @moduletag :database

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.BookingPages
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.PublicListing

  setup do
    setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
    :ok
  end

  test "an invitation-only type is not on the profile page" do
    user = insert(:user)
    plain = insert(:meeting_type, user: user, name: "Plain")
    hidden = insert(:meeting_type, user: user, name: "By invitation", invitation_only: true)

    ids = user.id |> MeetingTypeQueries.list_public_meeting_types() |> Enum.map(& &1.id)

    assert plain.id in ids
    refute hidden.id in ids

    offered = user.id |> MeetingTypes.get_public_meeting_types() |> Enum.map(& &1.id)
    assert offered == [plain.id]
  end

  test "an invitation-only type is not offered on a booking page" do
    user = insert(:user)
    profile = insert(:profile, user: user)
    page = insert(:booking_page, profile: profile)
    plain = insert(:meeting_type, user: user, name: "Plain")
    hidden = insert(:meeting_type, user: user, name: "By invitation", invitation_only: true)

    for type <- [plain, hidden],
        do: insert(:booking_page_meeting_type, booking_page: page, meeting_type: type)

    assert [%{id: id}] = BookingPages.list_meeting_types(page)
    assert id == plain.id

    assert [plain.id] == [plain, hidden] |> PublicListing.offered() |> Enum.map(& &1.id)
  end

  test "switching invitation-only off again restores the type's visibility" do
    user = insert(:user)
    type = insert(:meeting_type, user: user, is_private: false)

    {:ok, type} = MeetingTypes.set_invitation_only(type, true)
    assert type.invitation_only
    assert MeetingTypeQueries.list_public_meeting_types(user.id) == []

    {:ok, type} = MeetingTypes.set_invitation_only(type, false)
    refute type.invitation_only
    assert [%{id: id}] = MeetingTypeQueries.list_public_meeting_types(user.id)
    assert id == type.id
  end

  test "a group type cannot be invitation-only" do
    group = insert(:meeting_type, max_participants: 4)

    assert {:error, changeset} = MeetingTypes.set_invitation_only(group, true)

    assert {"Invitation links work only for one-to-one meeting types.", _opts} =
             changeset.errors[:invitation_only]

    refute Repo.get!(MeetingTypeSchema, group.id).invitation_only
  end

  test "an invitation-only type cannot become a group type" do
    type = insert(:meeting_type, invitation_only: true)

    changeset = MeetingTypeSchema.changeset(type, %{max_participants: 3})

    refute changeset.valid?

    assert {"Invitation links work only for one-to-one meeting types.", _opts} =
             changeset.errors[:invitation_only]
  end

  test "creating a type that is both invitation-only and a group type is refused" do
    user = insert(:user)

    assert {:error, changeset} =
             MeetingTypes.create_meeting_type(%{
               name: "Workshop",
               duration_minutes: 30,
               user_id: user.id,
               invitation_only: true,
               max_participants: 4
             })

    assert {"Invitation links work only for one-to-one meeting types.", _opts} =
             changeset.errors[:invitation_only]

    assert MeetingTypes.get_all_meeting_types(user.id) == []
  end

  test "an explicit nil for invitation_only does not crash" do
    type = insert(:meeting_type)

    changeset = MeetingTypeSchema.visibility_changeset(type, %{"invitation_only" => nil})

    refute Keyword.has_key?(changeset.errors, :invitation_only)
  end

  describe "the address of an invitation-only type listed on a page" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "joern")
      page = insert(:booking_page, profile: profile, slug: "coaching")

      type =
        insert(:meeting_type, user: user, name: "Intro", slug: "intro", is_private: true)

      insert(:booking_page_meeting_type, booking_page: page, meeting_type: type)
      %{profile: profile, page: page, type: type}
    end

    test "is /<username>/<slug>, not the page's, and returns to the page's when switched off",
         %{profile: profile, page: page, type: type} do
      assert BookingPages.meeting_type_path(profile, type) == "/joern/coaching/intro"
      assert BookingPages.serves?(page, type)
      assert BookingPages.published?(page)

      {:ok, type} = MeetingTypes.set_invitation_only(type, true)

      refute BookingPages.published?(page)
      assert BookingPages.home_page(type) == nil
      assert BookingPages.meeting_type_path(profile, type) == "/joern/intro"

      assert BookingPages.meeting_type_paths(profile, [type]) == %{type.id => "/joern/intro"}

      refute BookingPages.serves?(page, type)

      {:ok, type} = MeetingTypes.set_invitation_only(type, false)

      assert %{id: page_id} = BookingPages.home_page(type)
      assert page_id == page.id
      assert BookingPages.meeting_type_path(profile, type) == "/joern/coaching/intro"
      assert BookingPages.serves?(page, type)
    end
  end

  test "a one-to-one invitation-only type passes the main changeset without the flag in the params" do
    type = insert(:meeting_type, invitation_only: true)

    assert MeetingTypeSchema.changeset(type, %{name: "Renamed"}).valid?
  end

  test "duplicating keeps the flag" do
    type = insert(:meeting_type, invitation_only: true)

    assert {:ok, copy} = MeetingTypes.duplicate_meeting_type(type)
    assert copy.invitation_only
    assert copy.id != type.id
  end
end
