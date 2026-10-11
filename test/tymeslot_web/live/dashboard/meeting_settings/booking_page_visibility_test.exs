defmodule TymeslotWeb.Dashboard.MeetingSettings.BookingPageVisibilityTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.BookingPages
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.MeetingSettings.PageVisibility

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    profile = profile |> Changeset.change(username: "joern") |> Repo.update!()
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    %{profile: profile, page: page}
  end

  describe "PageVisibility" do
    test "rows put the username first and tick what lists the type", %{page: page} do
      type = %{id: 1, is_private: true}

      assert PageVisibility.rows("joern", [page], %{1 => MapSet.new([page.id])}, type) == [
               %{id: "profile", address: "joern", checked: false},
               %{id: to_string(page.id), address: "einfachiso", checked: true}
             ]

      assert PageVisibility.rows("joern", [page], %{}, nil) == []
    end

    test "a type is unlisted only when it is on no page", %{page: page} do
      refute PageVisibility.unlisted?(%{1 => MapSet.new([page.id])}, %{id: 1, is_private: true})
      assert PageVisibility.unlisted?(%{}, %{id: 1, is_private: true})
      refute PageVisibility.unlisted?(%{}, %{id: 1, is_private: false})
    end

    test "addresses stay empty until there are booking pages" do
      assert PageVisibility.addresses("joern", [], %{}, %{id: 1, is_private: false}) == []
    end
  end

  test "the editor lists a type on a page and the card names it", ctx do
    type = insert(:meeting_type, user: ctx.user, name: "ISO audit", is_private: true)
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")

    view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()
    assert has_element?(view, "[data-testid='unlisted-note']")

    view
    |> element("[phx-click='toggle_page_membership'][phx-value-page='#{ctx.page.id}']")
    |> render_click()

    assert BookingPages.memberships(ctx.profile.id)[type.id] == MapSet.new([ctx.page.id])
    refute has_element?(view, "[data-testid='unlisted-note']")

    view |> element("button", "Done") |> render_click()
    html = render(view)
    assert html =~ "/einfachiso"
    refute html =~ "Unlisted"
  end

  test "a page deleted in another tab fails with a flash, not a crash", ctx do
    type = insert(:meeting_type, user: ctx.user, name: "ISO audit")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")
    view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()

    {:ok, _deleted} = BookingPages.delete(ctx.page)

    view
    |> element("[phx-click='toggle_page_membership'][phx-value-page='#{ctx.page.id}']")
    |> render_click()

    assert BookingPages.memberships(ctx.profile.id) == %{}
    assert has_element?(view, "#app-flash-group-error", "Failed to update visibility")
  end
end
