defmodule TymeslotWeb.Live.Themes.PaperThemeTest do
  @moduledoc """
  Paper's booking page through the real routes: the overview's list of
  meeting types with their lengths and a paid type's price, the logo in
  the avatar's place, the schedule step's details beside the month
  calendar, the style block each colour mode writes, and the meeting pages
  in Paper's card. The shared flow suites book through it as through every
  theme in `ThemeTestMatrix`.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers

  alias Tymeslot.TestMocks
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @theme_id "3"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    seed_booking_account(@theme_id, "paper-organiser", "Etc/UTC")
  end

  defp customise(profile, settings),
    do: insert(:theme_customization, profile: profile, theme_id: @theme_id, settings: settings)

  test "the overview lists the meeting types in Paper's card", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, ".paper-theme-wrapper [data-testid='paper-overview'].booker-card")

    assert has_element?(
             view,
             "button.paper-type[data-duration='quick-chat'][aria-pressed='false']"
           )

    assert has_element?(view, "button.paper-type .paper-type__duration", "30 minutes")
    assert has_element?(view, "button[data-testid='next-step'][disabled]")

    view |> element("button[data-duration='quick-chat']") |> render_click()

    assert has_element?(view, "button[data-duration='quick-chat'][aria-pressed='true']")
    refute has_element?(view, "button[data-testid='next-step'][disabled]")
  end

  test "a paid meeting type shows its price in the organiser's currency",
       %{conn: conn, user: user, profile: profile} do
    insert(:connect_account, user: user, default_currency: "chf")

    insert(:meeting_type,
      user: user,
      name: "Strategy Session",
      duration_minutes: 60,
      payment_required: true,
      price_cents: 12_000
    )

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, "button.paper-type .paper-type__price", "CHF 120.00")
  end

  test "an uploaded logo takes the avatar's place", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
    assert has_element?(view, ".paper-intro img.paper-avatar")
    refute has_element?(view, ".paper-brand")

    logo = "themes/#{profile.id}/3/images/logo.png"
    customise(profile, %{"color_scheme" => "neutral", "logo_path" => logo})

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
    assert has_element?(view, ".paper-brand img.paper-logo[src='/uploads/#{logo}']")
    refute has_element?(view, ".paper-intro img.paper-avatar")
  end

  test "the schedule step puts the meeting's details beside the month calendar",
       %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat")

    assert has_element?(view, "[data-testid='paper-schedule'] .paper-details h1", "Quick Chat")
    assert has_element?(view, ".paper-details .paper-fact", "30 minutes")

    assert has_element?(
             view,
             ".paper-calendar button.calendar-nav-button[phx-click='next_month'][aria-label='Next month']"
           )

    assert has_element?(
             view,
             "[data-testid='schedule-actions'] button[data-testid='next-step'][disabled]"
           )
  end

  test "the colour mode decides the page's style block", %{conn: conn, profile: profile} do
    {:ok, _view, auto} = live(conn, ~p"/#{profile.username}")

    assert auto =~ "--theme-color-scheme: light dark;"
    assert auto =~ "@media (prefers-color-scheme: dark)"

    customise(profile, %{"color_scheme" => "cool", "colour_mode" => "dark"})

    {:ok, _view, dark} = live(conn, ~p"/#{profile.username}")

    assert dark =~ "--theme-color-scheme: dark;"
    assert dark =~ "--theme-canvas: #0b1120;"
    refute dark =~ "prefers-color-scheme"
  end

  test "the page loads Paper's stylesheet and classes", %{conn: conn, profile: profile} do
    html = conn |> get(~p"/#{profile.username}") |> html_response(200)

    assert html =~ "/assets/scheduling-theme-paper.css"
    assert html =~ ~s(class="scheduling-app theme-3 paper-theme")
  end

  test "the dashboard's and the onboarding wizard's pickers offer Paper" do
    assert {"Paper", "3"} in ThemeInfo.theme_options()
  end
end
