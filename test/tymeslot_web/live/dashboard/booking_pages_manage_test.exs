defmodule TymeslotWeb.Dashboard.BookingPagesManageTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :dashboard
  @moduletag :themes

  import ExUnit.CaptureLog
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.BookingPages
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    %{profile: profile |> Changeset.change(username: "joern") |> Repo.update!()}
  end

  test "creates a page from the dialog and opens its tab", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view |> element("[data-testid='new-booking-page']") |> render_click()

    view
    |> form("#new-booking-page-form", page: %{name: "einfachISO", slug: "einfachiso"})
    |> render_submit()

    [page] = BookingPages.list(profile.id)
    assert page.slug == "einfachiso"
    assert_patch(view, ~p"/dashboard/theme?#{[page: page.id]}")
  end

  test "the dialog refuses an address that is taken", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view |> element("[data-testid='new-booking-page']") |> render_click()

    html =
      view
      |> form("#new-booking-page-form", page: %{name: "Me again", slug: "joern"})
      |> render_submit()

    assert html =~ "has already been taken"
    assert BookingPages.list(profile.id) == []
  end

  # The main page's colours are copied once the page is written. A colour row
  # saved under rules since tightened is left out of the copy rather than
  # blocking the new page.
  test "a main page colour row the current rules reject does not block a new page", ctx do
    insert(:theme_customization, profile: ctx.profile, theme_id: "1", color_scheme: "no-such")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme")

    view |> element("[data-testid='new-booking-page']") |> render_click()

    log =
      capture_log(fn ->
        view
        |> form("#new-booking-page-form", page: %{name: "einfachISO", slug: "einfachiso"})
        |> render_submit()
      end)

    assert [page] = BookingPages.list(ctx.profile.id)
    assert_patch(view, ~p"/dashboard/theme?#{[page: page.id]}")
    assert log =~ "Skipped a colour row"
  end

  # The address follows the name, keystroke by keystroke, until the host
  # types an address of their own.
  test "the dialog suggests the address from the name as it is typed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view |> element("[data-testid='new-booking-page']") |> render_click()

    for name <- ["e", "einfachISO"] do
      view
      |> form("#new-booking-page-form", page: %{name: name})
      |> render_change(%{_target: ["page", "name"]})
    end

    assert has_element?(
             view,
             "#new-booking-page-form input[name='page[slug]'][value='einfachiso']"
           )

    view
    |> form("#new-booking-page-form", page: %{slug: "iso"})
    |> render_change(%{_target: ["page", "slug"]})

    view
    |> form("#new-booking-page-form", page: %{name: "einfachISO GmbH"})
    |> render_change(%{_target: ["page", "name"]})

    assert has_element?(view, "#new-booking-page-form input[name='page[slug]'][value='iso']")
  end

  test "the suggested address spells out umlauts and drops other accents", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view |> element("[data-testid='new-booking-page']") |> render_click()

    for {name, address} <- [{"Prüfung Süß", "pruefung-suess"}, {"ÄÖÜ Café", "aeoeue-cafe"}] do
      view
      |> form("#new-booking-page-form", page: %{name: name})
      |> render_change(%{_target: ["page", "name"]})

      assert has_element?(
               view,
               "#new-booking-page-form input[name='page[slug]'][value='#{address}']"
             )
    end
  end

  test "the new page button stops at the cap", %{conn: conn, profile: profile} do
    for n <- 1..BookingPages.max_pages(),
        do: insert(:booking_page, profile: profile, slug: "cap-#{n}")

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    assert has_element?(view, "[data-testid='new-booking-page'][disabled]")
  end

  test "a tab switches to its page", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "Einfach ISO")
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    assert has_element?(view, "#booking-page-tabs-tab-profile", "/joern")
    assert has_element?(view, "#booking-page-tabs-tab-#{page.id}", "Einfach ISO · /einfachiso")

    view |> element("#booking-page-tabs-tab-#{page.id}") |> render_click()

    assert_patch(view, ~p"/dashboard/theme?#{[page: page.id]}")
    assert has_element?(view, "#booking-page-tabs-tab-#{page.id}[aria-current='page']")
  end

  # Without its own feedback text the copy hook falls back to an English toast.
  test "the copy link button confirms in the host's language", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    feedback = "[data-copy-feedback='Scheduling link copied to clipboard!']"

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")
    assert has_element?(view, "#page-settings-copy" <> feedback)

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme?#{[page: page.id]}")
    assert has_element?(view, "#page-settings-#{page.id}-copy" <> feedback)
  end

  # The page comes from the address bar, so whatever is there resolves to one
  # of the profile's own pages or to none.
  test "an unknown or foreign page in the address falls back to the profile's tab", ctx do
    foreign = insert(:booking_page, profile: insert(:profile), slug: "elsewhere")

    for page_param <- ["abc", to_string(foreign.id)] do
      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: page_param]}")

      assert has_element?(view, "#booking-page-tabs-tab-profile[aria-current='page']")
      refute has_element?(view, "#booking-page-tabs-tab-#{foreign.id}")

      view |> element("[phx-click='select_theme'][phx-value-theme='2']") |> render_click()
    end

    assert Repo.reload!(foreign).booking_theme == "1"
    assert Repo.reload!(ctx.profile).booking_theme == "2"
  end

  test "ticking a meeting type lists it on the page, and unticking removes it", ctx do
    page = insert(:booking_page, profile: ctx.profile, slug: "einfachiso")
    type = insert(:meeting_type, user: ctx.user, name: "ISO audit")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: page.id]}")

    switch = "#page-settings-#{page.id}-type-#{type.id}"

    view |> element(switch) |> render_click()
    assert BookingPages.memberships(ctx.profile.id)[type.id] == MapSet.new([page.id])
    assert has_element?(view, switch <> "[aria-checked='true']")

    view |> element(switch) |> render_click()
    refute Map.has_key?(BookingPages.memberships(ctx.profile.id), type.id)
    assert has_element?(view, switch <> "[aria-checked='false']")
  end

  test "on the username's tab the checklist works the unlisted flag", ctx do
    type = insert(:meeting_type, user: ctx.user, name: "Automation call", is_private: false)
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme")

    assert has_element?(view, "#page-settings-type-#{type.id}[aria-checked='true']")

    view |> element("#page-settings-type-#{type.id}") |> render_click()

    assert Repo.reload!(type).is_private
    assert has_element?(view, "#page-settings-type-#{type.id}[aria-checked='false']")
  end

  test "a meeting type that is not the host's is not listed, and says so", ctx do
    page = insert(:booking_page, profile: ctx.profile, slug: "einfachiso")
    type = insert(:meeting_type, user: ctx.user, name: "ISO audit")
    foreign_type = insert(:meeting_type, name: "Someone else's")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: page.id]}")

    view
    |> element("#page-settings-#{page.id}-type-#{type.id}")
    |> render_click(%{"id" => to_string(foreign_type.id)})

    assert BookingPages.memberships(ctx.profile.id) == %{}

    assert has_element?(
             view,
             "#app-flash-group-error",
             "Could not update this page's meeting types. Please try again."
           )
  end

  test "the checklist shares the meeting type write limit", ctx do
    page = insert(:booking_page, profile: ctx.profile, slug: "einfachiso")
    type = insert(:meeting_type, user: ctx.user, name: "ISO audit")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: page.id]}")

    message = exhaust_write_limit(ctx.user)
    view |> element("#page-settings-#{page.id}-type-#{type.id}") |> render_click()

    assert BookingPages.memberships(ctx.profile.id) == %{}
    assert has_element?(view, "#app-flash-group-error", message)
    assert has_element?(view, "#page-settings-#{page.id}-type-#{type.id}[aria-checked='false']")
  end

  test "renames a page and moves its address", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "Old")
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme?#{[page: page.id]}")

    view
    |> form("#page-settings-#{page.id}-details", page: %{name: "einfachISO", slug: "iso"})
    |> render_submit()

    assert %{name: "einfachISO", slug: "iso"} = Repo.reload!(page)
    assert has_element?(view, "#booking-page-tabs-tab-#{page.id}", "einfachISO · /iso")
    assert has_element?(view, "#page-settings-#{page.id}-details input[value='einfachISO']")
  end

  test "emptying the page name says it can't be blank instead of crashing", ctx do
    page = insert(:booking_page, profile: ctx.profile, slug: "einfachiso", name: "Old")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: page.id]}")
    details = "#page-settings-#{page.id}-details"

    view |> form(details, page: %{name: "", slug: "einfachiso"}) |> render_change()
    assert has_element?(view, details, "can't be blank")

    view |> form(details, page: %{name: "", slug: "einfachiso"}) |> render_submit()
    assert has_element?(view, details, "can't be blank")
    assert Repo.reload!(page).name == "Old"
  end

  test "saving a page deleted in another tab says so and shows the profile's tab", ctx do
    page = insert(:booking_page, profile: ctx.profile, slug: "einfachiso", name: "Old")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: page.id]}")

    {:ok, _deleted} = BookingPages.delete(page)

    view
    |> form("#page-settings-#{page.id}-details", page: %{name: "New", slug: "einfachiso"})
    |> render_submit()

    assert has_element?(view, "#app-flash-group-error", "This booking page no longer exists.")
    assert_patch(view, ~p"/dashboard/theme")
    refute has_element?(view, "#page-settings-#{page.id}")
    assert has_element?(view, "#page-settings")
  end

  test "deletes a page after confirming", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme?#{[page: page.id]}")

    view |> element("[phx-click='show_delete']") |> render_click()
    view |> element("#page-settings-#{page.id}-delete button", "Delete page") |> render_click()

    assert BookingPages.list(profile.id) == []
    assert_patch(view, ~p"/dashboard/theme")
  end

  # Spends the rest of the user's meeting type write allowance and returns the
  # message the next refused write flashes.
  defp exhaust_write_limit(user) do
    Enum.find_value(
      Stream.repeatedly(fn -> RateLimiter.check_meeting_type_write_rate_limit(user.id) end),
      fn
        {:error, :rate_limited, message} -> message
        :ok -> nil
      end
    )
  end
end
