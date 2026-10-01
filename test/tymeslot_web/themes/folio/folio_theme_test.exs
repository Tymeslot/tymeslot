defmodule TymeslotWeb.Themes.Folio.FolioThemeTest do
  @moduledoc """
  Folio's own markup through the real booking routes: the full masthead on
  the overview (cover, portrait, name, headline and bio), the slim one and
  the month calendar from the schedule step on, the cover following the
  organiser's choice or upload, the page marked light or dark from its
  scheme, and the default pages inside Folio's card. The shared suites
  (`ThemeTestMatrix`) cover the booking flow itself.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.ThemeBookingFlowHelpers

  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Folio.Scheduling.Wrapper

  @theme_id "4"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  setup do
    %{profile: profile} = seed_booking_account(@theme_id, "folio-organiser", "UTC")
    %{profile: profile}
  end

  defp overview(profile) do
    {:ok, view, _html} = live(build_conn(), ~p"/#{profile.username}")
    view
  end

  defp schedule(profile) do
    {:ok, view, _html} = live(build_conn(), "/#{profile.username}/quick-chat")
    view
  end

  defp choose(profile, group, field, value) do
    {:ok, _customization} =
      ThemeCustomizations.apply_option(profile.id, @theme_id, group, %{
        "field" => field,
        "value" => value
      })
  end

  describe "the overview" do
    test "opens with the cover, the portrait and the organiser's name", %{profile: profile} do
      view = overview(profile)
      default_src = Presets.find_preset_by_id(:cover, "elegant-still-life").src

      assert has_element?(view, ".folio-theme-wrapper .folio-card--overview.booker-card")

      assert has_element?(
               view,
               ".folio-masthead--full [data-testid='folio-cover'][data-cover='elegant-still-life'] img[src='#{default_src}']"
             )

      assert has_element?(view, ".folio-masthead--full img.folio-portrait")
      assert has_element?(view, ".folio-masthead--full h1.folio-identity__name")
      refute has_element?(view, ".folio-masthead--full .folio-identity__meta")
    end

    test "shows the headline and the bio when the organiser has written them", %{
      profile: profile
    } do
      {:ok, _profile} =
        profile
        |> Repo.reload!()
        |> Profiles.update_intro(%{
          "headline" => "Coach for first-time managers",
          "bio" => "Ten years of leading teams.\n\nBook a first call below."
        })

      view = overview(profile)

      assert has_element?(
               view,
               ".folio-masthead--full [data-testid='profile-headline']",
               "Coach for first-time managers"
             )

      assert has_element?(
               view,
               ".folio-masthead--full [data-testid='profile-bio'] p",
               "Ten years"
             )
    end

    test "leaves the headline and the bio out when there are none", %{profile: profile} do
      view = overview(profile)

      refute has_element?(view, "[data-testid='profile-headline']")
      refute has_element?(view, "[data-testid='profile-bio']")
    end

    test "lists each meeting type as a card that marks its selection", %{profile: profile} do
      view = overview(profile)
      card = "[data-testid='duration-option'][data-duration='quick-chat']"

      assert has_element?(view, "#{card}[aria-pressed='false']", "Quick Chat")
      view |> element(card) |> render_click()
      assert has_element?(view, "#{card}[aria-pressed='true']")
      refute has_element?(view, "[data-testid='next-step'][disabled]")
    end
  end

  describe "the cover" do
    test "follows the organiser's choice", %{profile: profile} do
      choose(profile, :cover, "cover_value", "botanical")

      assert has_element?(
               overview(profile),
               "[data-cover='botanical'] img[src='/images/themes/covers/botanical.webp']"
             )
    end

    test "shows an uploaded cover from its sanitised path", %{profile: profile} do
      path = "themes/#{profile.id}/#{@theme_id}/images/a-cover.png"

      {:ok, _customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, @theme_id, %{
          "cover_value" => "custom",
          "cover_path" => path
        })

      assert has_element?(overview(profile), "[data-cover='custom'] img[src='/uploads/#{path}']")
    end
  end

  describe "light and dark" do
    test "a light scheme marks the page light", %{profile: profile} do
      assert has_element?(overview(profile), ".folio-theme-wrapper--light")
    end

    test "a dark scheme marks the page dark", %{profile: profile} do
      choose(profile, :palette, "scheme", "ink")

      view = overview(profile)
      assert has_element?(view, ".folio-theme-wrapper--dark")
      refute has_element?(view, ".folio-theme-wrapper--light")
    end

    test "mode/1 compares the canvas with the text, light without tokens" do
      assert Wrapper.mode(%Tokens{
               vars: %{"--theme-canvas" => "#111315", "--theme-text" => "#f2f2f0"}
             }) ==
               :dark

      assert Wrapper.mode(%Tokens{
               vars: %{"--theme-canvas" => "#faf7f2", "--theme-text" => "#1f1b16"}
             }) ==
               :light

      assert Wrapper.mode(nil) == :light
    end
  end

  describe "from the schedule step on" do
    test "the card starts with the slim masthead and a month calendar", %{profile: profile} do
      view = schedule(profile)

      assert has_element?(view, ".folio-card--schedule .folio-masthead--slim")
      refute has_element?(view, ".folio-masthead--full")
      assert has_element?(view, ".folio-masthead--slim .folio-identity__meta", "Quick Chat")
      assert has_element?(view, ".calendar-month-label")
      assert has_element?(view, "button[phx-click='next_month']")

      assert has_element?(
               view,
               "[data-testid='schedule-actions'] [data-testid='next-step'][disabled]"
             )
    end
  end
end
