defmodule TymeslotWeb.Dashboard.BookingPagesReadOnlyTest do
  @moduledoc """
  The Theme screen for a host whose plan no longer includes booking pages:
  their pages are shown read-only with an explanation, a new page asks for
  the upgrade instead of opening the dialog, and deleting stays open. The
  meeting type editor's page switches are disabled likewise, and a refused
  flip says why.
  """
  # The checker is configured globally.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :dashboard
  @moduletag :themes

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.BookingPages
  alias Tymeslot.Repo
  alias Tymeslot.Test.BookingPagesDeniedChecker

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    setup_config(:tymeslot, :feature_access_checker, BookingPagesDeniedChecker)
    profile = profile |> Changeset.change(username: "joern") |> Repo.update!()
    page = insert(:booking_page, profile: profile, name: "Audits", slug: "audits")
    %{profile: profile, page: page}
  end

  test "a page is shown read-only, its theme cannot be changed", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages?#{[page: ctx.page.id]}")

    assert has_element?(view, "[data-testid='booking-pages-locked']", "read-only")
    assert has_element?(view, "#page-settings-#{ctx.page.id} fieldset[disabled]")
    refute has_element?(view, "[phx-click='select_theme']")
    assert has_element?(view, "[phx-click='show_delete']:not([disabled])")
  end

  test "a forged rename is refused with the reason", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages?#{[page: ctx.page.id]}")

    view
    |> element("#page-settings-#{ctx.page.id}-details")
    |> render_submit(%{page: %{name: "Renamed", slug: "audits"}})

    assert Repo.reload!(ctx.page).name == "Audits"
    assert has_element?(view, "#app-flash-group-error", "read-only on your current plan")
  end

  test "the main page stays editable", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages")

    refute has_element?(view, "[data-testid='booking-pages-locked']")
    view |> element("[phx-click='select_theme'][phx-value-theme='2']") |> render_click()
    assert Repo.reload!(ctx.profile).booking_theme == "2"
  end

  test "a new page asks for the upgrade instead of opening the dialog", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages")

    view |> element("[data-testid='new-booking-page']") |> render_click()

    assert has_element?(view, "#new-booking-page-upgrade", "Extra booking pages need")
  end

  test "the page can still be deleted", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages?#{[page: ctx.page.id]}")

    view |> element("[phx-click='show_delete']") |> render_click()

    view
    |> element("#page-settings-#{ctx.page.id}-delete button", "Delete page")
    |> render_click()

    assert BookingPages.list(ctx.profile.id) == []
  end

  describe "the meeting type editor" do
    setup ctx do
      type = insert(:meeting_type, user: ctx.user, name: "ISO audit", is_private: false)
      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")
      view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()
      %{type: type, view: view}
    end

    test "disables the page switches, not the username's", ctx do
      page_switch = "#meeting-type-page-toggle-#{ctx.type.id}-#{ctx.page.id}"

      assert has_element?(ctx.view, page_switch <> "[disabled]")
      assert has_element?(ctx.view, page_switch <> "-reason", "read-only")

      ctx.view |> element("#meeting-type-private-toggle-#{ctx.type.id}") |> render_click()
      assert Repo.reload!(ctx.type).is_private
    end

    test "a forged page flip is refused with the reason", ctx do
      [_match, cid] =
        Regex.run(
          ~r/phx-target="(\d+)"/,
          ctx.view |> element("#meeting-type-private-toggle-#{ctx.type.id}") |> render()
        )

      ctx.view
      |> with_target("[data-phx-component='#{cid}']")
      |> render_click("toggle_page_membership", %{
        "id" => to_string(ctx.type.id),
        "page" => to_string(ctx.page.id),
        "listed" => "true"
      })

      assert BookingPages.memberships(ctx.profile.id) == %{}
      assert has_element?(ctx.view, "#app-flash-group-error", "read-only on your current plan")
      refute has_element?(ctx.view, "#app-flash-group-error", "Failed to update visibility")
    end
  end
end
