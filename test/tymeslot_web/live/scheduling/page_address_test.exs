defmodule TymeslotWeb.Live.Scheduling.PageAddressTest do
  @moduledoc """
  The organiser `PageAddress.settle/2` hands on with a settled address, which
  `ThemeHook` takes its theme from instead of looking the profile up again:
  wearing the page only where the URL is a page the visitor may see.
  """
  use Tymeslot.DataCase, async: true
  @moduletag :scheduling

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias TymeslotWeb.Live.Scheduling.PageAddress
  alias TymeslotWeb.Live.Scheduling.PreviewToken

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "1")
    page = insert(:booking_page, profile: profile, slug: "einfachiso", booking_theme: "2")

    %{user: user, profile: profile, page: page}
  end

  test "a published page's start page hands on the profile wearing the page", %{
    user: user,
    page: page
  } do
    type = insert(:meeting_type, user: user)
    :ok = BookingPages.set_meeting_type(page, type.id, true)

    assert {:ok, %{"page" => "einfachiso"}, :overview, organiser} =
             PageAddress.settle(%{"username" => "joern", "slug" => "einfachiso"}, :schedule)

    assert organiser.booking_page.id == page.id
    assert organiser.booking_theme == "2"
  end

  test "a draft page lends nothing to the meeting type URL it falls through to" do
    assert {:ok, %{"slug" => "einfachiso"}, :schedule, organiser} =
             PageAddress.settle(%{"username" => "joern", "slug" => "einfachiso"}, :schedule)

    assert organiser.booking_page == nil
    assert organiser.booking_theme == "1"
  end

  test "a draft page wears its look for its owner's preview", %{user: user} do
    params = %{
      "username" => "joern",
      "slug" => "einfachiso",
      "preview_token" => PreviewToken.sign(user.id)
    }

    assert {:ok, _params, :overview, organiser} = PageAddress.settle(params, :schedule)
    assert organiser.booking_theme == "2"
  end

  test "the username's own page hands on the bare profile", %{profile: profile} do
    assert {:ok, _params, :overview, organiser} =
             PageAddress.settle(%{"username" => "joern"}, :overview)

    assert organiser.id == profile.id
    assert organiser.booking_page == nil
  end

  test "a username nobody holds hands on no organiser" do
    assert {:ok, _params, :overview, nil} =
             PageAddress.settle(%{"username" => "nobody-here"}, :overview)
  end
end
