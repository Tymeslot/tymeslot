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
    assert Keyword.has_key?(changeset.errors, :invitation_only)
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
