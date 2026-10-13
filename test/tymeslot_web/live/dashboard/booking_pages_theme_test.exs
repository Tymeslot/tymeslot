defmodule TymeslotWeb.Dashboard.BookingPagesThemeTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :themes
  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.BookingPages
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    profile = profile |> Changeset.change(username: "joern") |> Repo.update!()
    page = insert(:booking_page, profile: profile, slug: "einfachiso", booking_theme: "1")
    %{profile: profile, page: page}
  end

  test "selecting a theme on a page's tab changes only the page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    view |> element("[phx-click='select_theme'][phx-value-theme='2']") |> render_click()

    assert Repo.reload!(ctx.page).booking_theme == "2"
    assert Repo.reload!(ctx.profile).booking_theme == "1"
    # The dashboard keeps the profile's own look: no overlaid profile reached it.
    assert :sys.get_state(view.pid).socket.assigns.profile.booking_page == nil
  end

  test "switching booking texts on for a page writes them to the page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    view |> element("#booking-text-form-#{ctx.page.id}-enabled") |> render_click()

    assert Repo.reload!(ctx.page).booking_text_enabled
    refute Repo.reload!(ctx.profile).booking_text_enabled
    assert :sys.get_state(view.pid).socket.assigns.profile.booking_page == nil
  end

  # The page's write is what fails here; the form renders a profile changeset
  # and must still show why, once, rather than an error-free form.
  test "a page's text that breaks a rule shows why and writes nothing", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    view |> element("#booking-text-form-#{ctx.page.id}-enabled") |> render_click()
    saved_heading = Repo.reload!(ctx.page).booking_heading

    html =
      view
      |> form("#booking-text-form-#{ctx.page.id}-form",
        profile_schema: %{booking_heading: String.duplicate("a", 61)}
      )
      |> render_change()

    assert [_before, _after] = String.split(html, "should be at most 60 character")
    assert html =~ "Unsaved changes"
    assert Repo.reload!(ctx.page).booking_heading == saved_heading
    assert Repo.reload!(ctx.profile).booking_heading == nil
  end

  test "a page's texts saved after it was deleted in another tab say so", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    {:ok, _deleted} = BookingPages.delete(ctx.page)
    view |> element("#booking-text-form-#{ctx.page.id}-enabled") |> render_click()

    assert has_element?(view, "#app-flash-group-error", "This booking page no longer exists.")
    assert_patch(view, ~p"/dashboard/theme")
    refute has_element?(view, "#booking-text-form-#{ctx.page.id}")
    refute Repo.reload!(ctx.profile).booking_text_enabled
  end

  # The page held for the theme cards was read before the texts were saved, so
  # picking a theme from it must not hand the form the texts it still carries.
  # The click's own render is the one checked: the flash it sends makes the
  # dashboard re-read the page a moment later, which would hide a stale form.
  test "selecting a theme after saving a page's texts keeps them", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    view |> element("#booking-text-form-#{ctx.page.id}-enabled") |> render_click()

    view
    |> form("#booking-text-form-#{ctx.page.id}-form",
      profile_schema: %{booking_heading: "Book einfachISO"}
    )
    |> render_change()

    html = view |> element("[phx-click='select_theme'][phx-value-theme='2']") |> render_click()

    page = Repo.reload!(ctx.page)
    assert page.booking_theme == "2"
    assert page.booking_heading == "Book einfachISO"
    assert html =~ ~s(value="Book einfachISO")
    assert render(view) =~ ~s(value="Book einfachISO")
  end

  test "the colour editor on a page's tab edits the page's colours", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme/customize/1?#{[page: ctx.page.id]}")

    assert render(view) =~ "/einfachiso"

    view
    |> element("[phx-click='theme:select_color_scheme'][phx-value-scheme='purple']")
    |> render_click()

    assert %{color_scheme: "purple"} =
             ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "1")

    assert ThemeCustomizations.get_by_profile_and_theme(ctx.profile.id, "1") == nil
  end

  test "closing the colour editor returns to the page's tab", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme/customize/1?#{[page: ctx.page.id]}")

    view |> element("[phx-click='close_customization']") |> render_click()

    assert_patch(view, ~p"/dashboard/theme?#{[page: ctx.page.id]}")
  end

  test "the username's tab still edits the profile", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme")

    view |> element("[phx-click='select_theme'][phx-value-theme='2']") |> render_click()

    assert Repo.reload!(ctx.profile).booking_theme == "2"
    assert Repo.reload!(ctx.page).booking_theme == "1"
  end
end
