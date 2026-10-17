defmodule TymeslotWeb.Themes.Folio.FolioThemeTest do
  @moduledoc """
  Folio's own markup through the real booking routes: the full masthead on
  the overview (cover, portrait, name, headline and bio), the calendar
  opening below on the same page, the cover following the
  organiser's choice or upload, the page marked light or dark from its
  scheme, and the default pages inside Folio's card. The shared suites
  (`ThemeTestMatrix`) cover the booking flow itself.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Folio.Scheduling.Components.ConfirmationComponent
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
    test "introduces the meeting types in Folio's own words", %{profile: profile} do
      view = overview(profile)

      assert has_element?(view, "h2", "Ways to work with me")
      refute has_element?(view, "#offer-step > p.folio-muted")
    end

    test "shows the organiser's own instruction when they have written one", %{profile: profile} do
      profile
      |> Changeset.change(%{
        booking_text_enabled: true,
        booking_instruction: "Choose a session."
      })
      |> Repo.update!()

      view = overview(profile)

      assert has_element?(view, "#offer-step > p.folio-muted", "Choose a session.")
    end

    test "opens with the cover, the portrait and the organiser's name", %{profile: profile} do
      view = overview(profile)
      default_src = Presets.find_preset_by_id(:cover, "elegant-still-life").src

      assert has_element?(view, ".folio-theme-wrapper #masthead-step .folio-masthead--full")
      assert has_element?(view, ".folio-theme-wrapper #offer-step.booker-card")

      assert has_element?(
               view,
               ".folio-masthead--full [data-testid='folio-cover'][data-cover='elegant-still-life'] img[src='#{default_src}']"
             )

      assert has_element?(view, ".folio-masthead--full img.folio-portrait")
      assert has_element?(view, ".folio-masthead--full h1.folio-identity__name")
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

    test "lists each meeting type as a card; choosing one opens the calendar below and marks it",
         %{profile: profile} do
      view = overview(profile)
      card = "[data-testid='duration-option'][data-duration='quick-chat']"

      assert has_element?(view, "#{card}", "Quick Chat")
      refute has_element?(view, "#{card}[aria-current]")
      refute has_element?(view, "[data-testid='next-step']")

      view |> element(card) |> render_click()
      assert has_element?(view, "#when-step[data-moment-state='current']")
      assert has_element?(view, "#offer-step #{card}[aria-current='true']")
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

  describe "a meeting type's own link" do
    test "opens the page with that type chosen and the calendar below", %{profile: profile} do
      view = schedule(profile)

      assert has_element?(view, ".folio-masthead--full")
      assert has_element?(view, "#offer-step .folio-meeting--chosen", "Quick Chat")
      assert has_element?(view, "#when-step .calendar-month-label")
      assert has_element?(view, "#when-step button[phx-click='next_month']")
      refute has_element?(view, "[data-testid='next-step']")
    end
  end

  describe "the confirmation" do
    # The details read minutes, never the duration slug the flow carries.
    test "without a meeting type, the duration shows minutes" do
      html = confirmation_html(%{})

      assert html =~ ~r/<dd>\s*30 min\s*<\/dd>/
      refute html =~ "30-minutes"
      assert html =~ "See you on Thursday 10 September 2026, Alice"
    end

    test "with no name to say, the headline ends at the date" do
      html = confirmation_html(%{name: "  "})

      assert html =~ "See you on Thursday 10 September 2026<"
      refute html =~ "2026, "
    end

    test "a moved booking says the new day instead, by name" do
      html = confirmation_html(%{is_rescheduling: true})

      assert html =~ "See you on Thursday 10 September 2026 instead, Alice"
      refute html =~ "See you on Thursday 10 September 2026,"
    end

    test "a moved booking with no name to say ends at the word instead" do
      html = confirmation_html(%{is_rescheduling: true, name: "  "})

      assert html =~ "See you on Thursday 10 September 2026 instead<"
      refute html =~ "instead, "
    end
  end

  describe "offered" do
    test "the dashboard and onboarding pickers list Folio" do
      assert {"Folio", "4"} in ThemeInfo.theme_options()
    end
  end

  defp confirmation_html(overrides) do
    render_component(
      ConfirmationComponent,
      Map.merge(
        %{
          id: "confirmation-step",
          locale: "en",
          duration: "30-minutes",
          username_context: "hostuser",
          selected_date: "2026-09-10",
          selected_time: "10:00",
          user_timezone: "UTC",
          email: "guest@example.com",
          guest_emails: [],
          name: "Alice",
          organizer_profile: build(:profile, full_name: "Jane Organizer"),
          meeting_type: nil,
          meeting_status: "confirmed",
          meeting_uid: "abc123",
          custom_fields_snapshot: [],
          custom_field_answers: %{},
          is_rescheduling: false,
          theme_tokens: nil
        },
        overrides
      )
    )
  end
end
