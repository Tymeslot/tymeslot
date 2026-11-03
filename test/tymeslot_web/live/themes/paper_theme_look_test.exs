defmodule TymeslotWeb.Live.Themes.PaperThemeLookTest do
  @moduledoc """
  How Paper's booking page looks and speaks through the real routes: the
  style block each colour mode writes, Paper's stylesheet and classes, its
  neutral voice and the organiser's own booking text in its place, and
  Paper's place in the theme pickers. The journey itself is covered by
  `PaperThemeTest`.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Repo
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

  test "the colour mode decides the page's style block", %{conn: conn, profile: profile} do
    {:ok, _view, auto} = live(conn, ~p"/#{profile.username}")

    assert auto =~ "--theme-color-scheme: light dark;"
    assert auto =~ "@media (prefers-color-scheme: dark)"

    customise(profile, %{"color_scheme" => "paper_arctic", "colour_mode" => "dark"})

    {:ok, _view, dark} = live(conn, ~p"/#{profile.username}")

    assert dark =~ "--theme-color-scheme: dark;"
    assert dark =~ "--theme-canvas: #0c1426;"
    refute dark =~ "prefers-color-scheme"
  end

  test "the page loads Paper's stylesheet and classes", %{conn: conn, profile: profile} do
    html = conn |> get(~p"/#{profile.username}") |> html_response(200)

    assert html =~ "/assets/scheduling-theme-paper.css"
    assert html =~ ~s(class="scheduling-app theme-3 paper-theme")
  end

  test "the overview speaks in Paper's neutral voice", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, ".paper-title", "Book a meeting with")
    assert has_element?(view, ".paper-intro__instruction", "Select a meeting type")
    refute has_element?(view, ".paper-intro__greeting")
  end

  test "the organiser's own booking text replaces Paper's voice",
       %{conn: conn, profile: profile} do
    profile
    |> Changeset.change(%{
      booking_text_enabled: true,
      booking_heading: "Ready to grow your business?",
      booking_greeting: "I am Ana.",
      booking_instruction: "Choose a session."
    })
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, ".paper-title", "Ready to grow your business?")
    assert has_element?(view, ".paper-intro__greeting", "I am Ana.")
  end

  test "the organiser's blank greeting and instruction leave no paragraph behind",
       %{conn: conn, profile: profile} do
    profile
    |> Changeset.change(%{
      booking_text_enabled: true,
      booking_heading: "Ready to grow your business?",
      booking_greeting: nil,
      booking_instruction: nil
    })
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, ".paper-title", "Ready to grow your business?")
    refute has_element?(view, ".paper-intro__greeting")
    # Blank means unsaid: Paper's own instruction does not stand in for it.
    refute has_element?(view, ".paper-intro__instruction")
  end

  test "the dashboard's and the onboarding wizard's pickers offer Paper" do
    assert {"Paper", "3"} in ThemeInfo.theme_options()
  end
end
