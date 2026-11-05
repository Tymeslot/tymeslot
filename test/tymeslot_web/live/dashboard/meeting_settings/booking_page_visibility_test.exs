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
  alias TymeslotWeb.Endpoint

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
               %{id: to_string(page.id), address: "joern/einfachiso", checked: true}
             ]

      assert PageVisibility.rows("joern", [page], %{}, nil) == []
    end

    test "rows are none without a username, since every address is under it", %{page: page} do
      assert PageVisibility.rows(nil, [page], %{}, %{id: 1, is_private: false}) == []
    end

    test "a type is unlisted only when it is on no page", %{page: page} do
      refute PageVisibility.unlisted?(%{1 => MapSet.new([page.id])}, %{id: 1, is_private: true})
      assert PageVisibility.unlisted?(%{}, %{id: 1, is_private: true})
      refute PageVisibility.unlisted?(%{}, %{id: 1, is_private: false})
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
    # The card's badge is the type's one address, under the page listing it.
    assert has_element?(view, "[data-testid='meeting-type-link']", "/joern/einfachiso/iso-audit")
    refute render(view) =~ "Unlisted"
  end

  test "the editor's link to a type only a page lists is under that page", ctx do
    type = insert(:meeting_type, user: ctx.user, name: "ISO audit", is_private: true)
    :ok = BookingPages.set_meeting_type(ctx.page, type.id, true)
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")

    view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()

    assert has_element?(
             view,
             "#copy-booking-link-#{type.id}[data-copy-text$='/joern/einfachiso/iso-audit']"
           )
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

  test "a switch does what the host saw when another tab changed it meanwhile", ctx do
    type = insert(:meeting_type, user: ctx.user, name: "ISO audit", is_private: false)
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")
    view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()

    # Another tab unlists it from the username's page; this one still shows
    # it listed, and the host switches it off.
    type |> Changeset.change(is_private: true) |> Repo.update!()
    view |> element("#meeting-type-private-toggle-#{type.id}") |> render_click()
    assert Repo.reload!(type).is_private

    # A page's switch sets the state it asks for, not the opposite of the
    # listings held here: asking twice to list leaves it listed.
    page_switch = "#meeting-type-page-toggle-#{type.id}-#{ctx.page.id}"
    view |> element(page_switch) |> render_click(%{"listed" => "true"})
    view |> element(page_switch) |> render_click(%{"listed" => "true"})

    assert BookingPages.memberships(ctx.profile.id)[type.id] == MapSet.new([ctx.page.id])
  end

  describe "a host without a username" do
    setup %{profile: profile} do
      %{profile: profile |> Changeset.change(username: nil) |> Repo.update!()}
    end

    test "sees no \"Show on /\" switch, but what to do first", ctx do
      type = insert(:meeting_type, user: ctx.user, name: "ISO audit")
      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")
      view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()

      assert has_element?(view, "[data-testid='visibility-needs-username']")
      refute render(view) =~ "Show on /"
      refute has_element?(view, "[phx-click='toggle_private']")
      refute has_element?(view, "[phx-click='toggle_page_membership']")
    end

    test "gets no bare address as the link editor's prefix", ctx do
      type = insert(:meeting_type, user: ctx.user, name: "ISO audit")
      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")
      view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()

      # Without a username the editor offers no link to edit; send the event
      # its link button would, to the component that owns it.
      [_match, cid] =
        Regex.run(
          ~r/phx-target="(\d+)"/,
          view |> element("button[phx-click='close_edit_overlay']", "Done") |> render()
        )

      view
      |> with_target("[data-phx-component='#{cid}']")
      |> render_click("open_slug_modal", %{})

      assert has_element?(view, "#booking-link-modal")
      refute has_element?(view, "#booking-link-modal", Endpoint.url())
    end
  end
end
