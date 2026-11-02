defmodule TymeslotWeb.Dashboard.BookingPagesReadOnlyTest do
  @moduledoc """
  The Theme screen for a host whose plan no longer includes booking pages:
  their pages are shown read-only with an explanation, a new page asks for
  the upgrade instead of opening the dialog, and deleting stays open.
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
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    assert has_element?(view, "[data-testid='booking-pages-locked']", "read-only")
    assert has_element?(view, "#page-settings-#{ctx.page.id} fieldset[disabled]")
    refute has_element?(view, "[phx-click='select_theme']")
    assert has_element?(view, "[phx-click='show_delete']:not([disabled])")
  end

  test "a forged rename is refused with the reason", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    view
    |> element("#page-settings-#{ctx.page.id}-details")
    |> render_submit(%{page: %{name: "Renamed", slug: "audits"}})

    assert Repo.reload!(ctx.page).name == "Audits"
    assert has_element?(view, "#app-flash-group-error", "read-only on your current plan")
  end

  test "the main page stays editable", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme")

    refute has_element?(view, "[data-testid='booking-pages-locked']")
    view |> element("[phx-click='select_theme'][phx-value-theme='2']") |> render_click()
    assert Repo.reload!(ctx.profile).booking_theme == "2"
  end

  test "a new page asks for the upgrade instead of opening the dialog", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme")

    view |> element("[data-testid='new-booking-page']") |> render_click()

    assert has_element?(view, "#new-booking-page-upgrade", "Extra booking pages need")
  end

  test "the page can still be deleted", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    view |> element("[phx-click='show_delete']") |> render_click()

    view
    |> element("#page-settings-#{ctx.page.id}-delete button", "Delete page")
    |> render_click()

    assert BookingPages.list(ctx.profile.id) == []
  end
end
