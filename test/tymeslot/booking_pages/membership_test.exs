defmodule Tymeslot.BookingPages.MembershipTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :meeting_types

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageMeetingTypeSchema
  alias Tymeslot.Repo

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user)
    page = insert(:booking_page, profile: profile)
    %{user: user, profile: profile, page: page}
  end

  test "lists the types ticked for the page, in the host's order", ctx do
    second = insert(:meeting_type, user: ctx.user, name: "B", sort_order: 2)
    first = insert(:meeting_type, user: ctx.user, name: "A", sort_order: 1)
    _unticked = insert(:meeting_type, user: ctx.user, name: "C", sort_order: 0)

    :ok = BookingPages.set_meeting_type(ctx.page, second.id, true)
    :ok = BookingPages.set_meeting_type(ctx.page, first.id, true)

    assert ctx.page |> BookingPages.list_meeting_types() |> Enum.map(& &1.name) == ["A", "B"]
  end

  test "leaves out inactive types and types with no rows", ctx do
    inactive = insert(:meeting_type, user: ctx.user, is_active: false)
    :ok = BookingPages.set_meeting_type(ctx.page, inactive.id, true)

    assert BookingPages.list_meeting_types(ctx.page) == []
  end

  test "ticking twice and unticking are both safe", ctx do
    type = insert(:meeting_type, user: ctx.user)

    :ok = BookingPages.set_meeting_type(ctx.page, type.id, true)
    :ok = BookingPages.set_meeting_type(ctx.page, type.id, true)
    assert [_one] = BookingPages.list_meeting_types(ctx.page)

    :ok = BookingPages.set_meeting_type(ctx.page, type.id, false)
    :ok = BookingPages.set_meeting_type(ctx.page, type.id, false)
    assert BookingPages.list_meeting_types(ctx.page) == []
  end

  test "listing a type on a page deleted meanwhile fails instead of raising", ctx do
    type = insert(:meeting_type, user: ctx.user)
    {:ok, _deleted} = BookingPages.delete(ctx.page)

    assert {:error, _reason} = BookingPages.set_meeting_type(ctx.page, type.id, true)
  end

  test "never lists another user's type, even with a membership row for it", ctx do
    stranger = insert(:user)
    foreign = insert(:meeting_type, user: stranger, name: "Foreign")
    own = insert(:meeting_type, user: ctx.user, name: "Own")

    Repo.insert!(%BookingPageMeetingTypeSchema{
      booking_page_id: ctx.page.id,
      meeting_type_id: foreign.id
    })

    :ok = BookingPages.set_meeting_type(ctx.page, own.id, true)

    assert ctx.page |> BookingPages.list_meeting_types() |> Enum.map(& &1.name) == ["Own"]
  end

  test "refuses to list another account's type and leaves no row", ctx do
    foreign = insert(:meeting_type, user: insert(:user))

    assert {:error, :not_found} = BookingPages.set_meeting_type(ctx.page, foreign.id, true)
    assert Repo.all(BookingPageMeetingTypeSchema) == []
  end

  test "refuses to list a type that does not exist", ctx do
    assert {:error, :not_found} = BookingPages.set_meeting_type(ctx.page, 0, true)
    assert Repo.all(BookingPageMeetingTypeSchema) == []
  end

  test "taking a type off one page leaves the same type on another", ctx do
    other_page = insert(:booking_page, profile: ctx.profile)
    type = insert(:meeting_type, user: ctx.user)

    :ok = BookingPages.set_meeting_type(ctx.page, type.id, true)
    :ok = BookingPages.set_meeting_type(other_page, type.id, true)
    :ok = BookingPages.set_meeting_type(ctx.page, type.id, false)

    assert BookingPages.list_meeting_types(ctx.page) == []
    assert [_one] = BookingPages.list_meeting_types(other_page)
  end

  test "memberships maps each type to its pages", ctx do
    other_page = insert(:booking_page, profile: ctx.profile)
    type = insert(:meeting_type, user: ctx.user)
    lonely = insert(:meeting_type, user: ctx.user)

    :ok = BookingPages.set_meeting_type(ctx.page, type.id, true)
    :ok = BookingPages.set_meeting_type(other_page, type.id, true)

    memberships = BookingPages.memberships(ctx.profile.id)

    assert memberships[type.id] == MapSet.new([ctx.page.id, other_page.id])
    refute Map.has_key?(memberships, lonely.id)
  end
end
