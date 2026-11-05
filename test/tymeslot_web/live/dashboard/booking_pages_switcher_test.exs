defmodule TymeslotWeb.Dashboard.BookingPagesSwitcherTest do
  @moduledoc """
  The Theme screen's page view: the switcher, a page's own settings first,
  the draft state, the delete warning, and the theme flash; and the Embed
  screen keeping its page across a reload.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :dashboard
  @moduletag :themes

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.BookingPages
  alias Tymeslot.Repo

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    %{profile: profile |> Changeset.change(username: "joern") |> Repo.update!()}
  end

  describe "switcher" do
    test "a few short names are tabs, the main page named as such", ctx do
      page = insert(:booking_page, profile: ctx.profile, name: "Audits", slug: "audits")
      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages")

      assert has_element?(view, "#booking-page-tabs-tab-profile", "Main page")
      assert has_element?(view, "#booking-page-tabs-tab-#{page.id}", "Audits")
    end

    test "many pages are a select only, which switches the page", ctx do
      pages = for n <- 1..5, do: insert(:booking_page, profile: ctx.profile, slug: "p-#{n}")
      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages")

      refute has_element?(view, "#booking-page-tabs")

      target = List.last(pages)
      view |> form("#booking-page-select", %{page: target.id}) |> render_change()

      assert_patch(view, ~p"/dashboard/pages?#{[page: target.id]}")
      assert has_element?(view, "#page-settings-#{target.id}")
    end

    test "long names are a select too", ctx do
      insert(:booking_page,
        profile: ctx.profile,
        name: "Workshops for teams and organisations across Europe",
        slug: "workshops"
      )

      insert(:booking_page, profile: ctx.profile, name: "Office hours for students", slug: "oh")
      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages")

      refute has_element?(view, "#booking-page-tabs")
      assert has_element?(view, "#booking-page-select option", "Office hours for students")
    end
  end

  test "the page's own settings come before the themes", ctx do
    page = insert(:booking_page, profile: ctx.profile, slug: "audits")
    {:ok, _view, html} = live(ctx.conn, ~p"/dashboard/pages?#{[page: page.id]}")

    {settings_at, _len} = :binary.match(html, ~s(id="page-settings-#{page.id}"))
    {themes_at, _len} = :binary.match(html, "phx-click=\"select_theme\"")
    assert settings_at < themes_at
  end

  describe "draft" do
    test "a page listing nothing is marked a draft until it lists a type", ctx do
      page = insert(:booking_page, profile: ctx.profile, name: "Audits", slug: "audits")
      type = insert(:meeting_type, user: ctx.user, name: "Audit", duration_minutes: 45)
      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages?#{[page: page.id]}")

      assert has_element?(view, "#booking-page-tabs-tab-#{page.id}", "Draft")
      assert has_element?(view, "[data-testid='page-draft']")
      assert has_element?(view, "[data-testid='page-draft-note']")
      assert has_element?(view, "#page-settings-#{page.id}", "45 min")

      view |> element("#page-settings-#{page.id}-type-#{type.id}") |> render_click()

      refute has_element?(view, "[data-testid='page-draft']")
      refute has_element?(view, "#booking-page-tabs-tab-#{page.id}", "Draft")
    end
  end

  test "the delete warning names the types the page alone lists", ctx do
    page = insert(:booking_page, profile: ctx.profile, name: "Audits", slug: "audits")
    only_here = insert(:meeting_type, user: ctx.user, name: "Deep audit", is_private: true)
    on_main = insert(:meeting_type, user: ctx.user, name: "Intro", is_private: false)
    :ok = BookingPages.set_meeting_type(page, only_here.id, true)
    :ok = BookingPages.set_meeting_type(page, on_main.id, true)

    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages?#{[page: page.id]}")
    view |> element("[phx-click='show_delete']") |> render_click()

    warning = "#page-settings-#{page.id}-delete"
    assert has_element?(view, warning, "will lead to your main page at /joern")
    assert has_element?(view, warning, "websites that embed it will show your main page")
    assert has_element?(view, "[data-testid='delete-page-unlisted-types'] li", "Deep audit")
    refute has_element?(view, "[data-testid='delete-page-unlisted-types'] li", "Intro")
  end

  test "the theme flash names the page", ctx do
    page = insert(:booking_page, profile: ctx.profile, name: "Audits", slug: "audits")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages?#{[page: page.id]}")

    view |> element("[phx-click='select_theme'][phx-value-theme='2']") |> render_click()

    assert has_element?(view, "#app-flash-group-info", "Theme for Audits updated to Rhythm")
  end

  test "a page renamed in another tab is renamed here too", ctx do
    page = insert(:booking_page, profile: ctx.profile, name: "Audits", slug: "audits")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/pages?#{[page: page.id]}")

    {:ok, _renamed} = BookingPages.update_details(page, %{"name" => "Reviews"})

    # The notice reaches the screen through a component update the dashboard
    # sends itself, one message behind the first render.
    _html = render(view)
    assert has_element?(view, "#booking-page-tabs-tab-#{page.id}", "Reviews")
    assert has_element?(view, "#page-settings-#{page.id}-details input[value='Reviews']")
  end

  test "the embed picker keeps its page in the address", ctx do
    page = insert(:booking_page, profile: ctx.profile, name: "Audits", slug: "audits")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/embed")

    view |> form("#embed-page-picker", %{page: page.id}) |> render_change()
    assert_patch(view, ~p"/dashboard/embed?#{[page: page.id]}")

    {:ok, reloaded, _html} = live(ctx.conn, ~p"/dashboard/embed?#{[page: page.id]}")
    assert has_element?(reloaded, "#embed-page-picker option[value='#{page.id}'][selected]")
    assert render(reloaded) =~ "/joern/audits"
  end
end
