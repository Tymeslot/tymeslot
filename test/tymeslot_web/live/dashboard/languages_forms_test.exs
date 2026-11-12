defmodule TymeslotWeb.Dashboard.LanguagesFormsTest do
  @moduledoc """
  The language bar on the forms that edit translatable texts other than a
  meeting type's: the booking page text card, the profile intro and the venue
  modal. On each, the bar opens a translation, saving it stores the
  translation without touching the original, and saving the original
  afterwards keeps it. Also: a translation typed but not saved survives
  switching language, and saving in a language another tab has removed says
  why rather than crashing.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :i18n
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.ContentTranslations
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Venues.VenueSchema

  setup :setup_dashboard_user

  setup %{profile: profile} do
    RateLimiter.clear_all()

    profile =
      profile
      |> Changeset.change(
        username: "lingo-forms",
        translation_locales: ["de", "fr"],
        headline: "Career coach",
        bio: "I help new managers.",
        booking_text_enabled: true,
        booking_heading: "Ready to talk?",
        booking_greeting: "I am Sarah.",
        booking_instruction: "Choose a session."
      )
      |> Repo.update!()

    %{profile: profile}
  end

  # Leaving a translation is handed to its editor (`send_update`), which then
  # tells the dashboard to switch (`send/2`): two messages the LiveView
  # handles after the click, so the test waits for each before reading back.
  defp choose(view, component, locale) do
    view |> element("##{component}-bar button[data-locale='#{locale}']") |> render_click()
    _editor = :sys.get_state(view.pid)
    _dashboard = :sys.get_state(view.pid)
    :ok
  end

  defp translate(view, component, texts),
    do: view |> form("##{component}-editor-form", %{"translation" => texts}) |> render_submit()

  defp draft(view, component, texts),
    do: view |> form("##{component}-editor-form", %{"translation" => texts}) |> render_change()

  defp stored(record, locale, path), do: ContentTranslations.translation(record, locale, path)

  describe "the booking page text card" do
    @component "booking-text-form-translations"

    test "saves a translation apart from the original, which a later autosave keeps", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/pages")

      choose(view, @component, "de")
      assert has_element?(view, "##{@component}-editor")
      translate(view, @component, %{"booking_heading" => "Bereit zu reden?"})

      saved = Repo.reload!(profile)
      assert stored(saved, "de", "booking_heading") == "Bereit zu reden?"
      assert saved.booking_heading == "Ready to talk?"

      choose(view, @component, "en")

      view
      |> form("#booking-text-form-form", profile_schema: %{booking_heading: "Shall we talk?"})
      |> render_change()

      saved = Repo.reload!(profile)
      assert saved.booking_heading == "Shall we talk?"
      assert stored(saved, "de", "booking_heading") == "Bereit zu reden?"
    end
  end

  describe "the profile intro" do
    test "saves a translation apart from the original, which a later save keeps", %{
      conn: conn,
      profile: profile
    } do
      component = "intro-translations-#{profile.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      choose(view, component, "de")
      translate(view, component, %{"headline" => "Karrierecoach"})

      saved = Repo.reload!(profile)
      assert stored(saved, "de", "headline") == "Karrierecoach"
      assert saved.headline == "Career coach"

      choose(view, component, "en")

      view
      |> form("#intro-form", profile_intro: %{headline: "Leadership coach", bio: "Still here."})
      |> render_submit()

      saved = Repo.reload!(profile)
      assert saved.headline == "Leadership coach"
      assert stored(saved, "de", "headline") == "Karrierecoach"
    end
  end

  describe "the venue modal" do
    test "saves a translation apart from the original, which a later save keeps", %{
      conn: conn,
      user: user
    } do
      venue = insert(:venue, user: user, name: "Studio", description: "Old Street 1")
      component = "venue-translations-#{venue.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/locations")

      view |> element("[phx-click='edit_venue'][phx-value-id='#{venue.id}']") |> render_click()
      choose(view, component, "de")
      translate(view, component, %{"name" => "Atelier"})

      saved = Repo.get!(VenueSchema, venue.id)
      assert stored(saved, "de", "name") == "Atelier"
      assert saved.name == "Studio"

      choose(view, component, "en")

      view
      |> form("#venue-form", %{"venue" => %{"name" => "Main studio"}})
      |> render_submit()

      saved = Repo.get!(VenueSchema, venue.id)
      assert saved.name == "Main studio"
      assert stored(saved, "de", "name") == "Atelier"
    end
  end

  describe "switching language with a translation not yet saved" do
    test "saves it on the way back to the original", %{conn: conn, profile: profile} do
      component = "intro-translations-#{profile.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      choose(view, component, "de")
      draft(view, component, %{"headline" => "Karrierecoach"})
      choose(view, component, "en")

      assert stored(Repo.reload!(profile), "de", "headline") == "Karrierecoach"
      refute has_element?(view, "##{component}-editor")
      assert has_element?(view, "#intro-form")
    end

    test "saves it on the way to another translation language", %{conn: conn, profile: profile} do
      component = "intro-translations-#{profile.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      choose(view, component, "de")
      draft(view, component, %{"headline" => "Karrierecoach"})
      choose(view, component, "fr")

      assert stored(Repo.reload!(profile), "de", "headline") == "Karrierecoach"
      assert has_element?(view, "##{component}-bar button[data-locale='fr'][aria-pressed='true']")
      refute has_element?(view, "##{component}-editor input[value='Karrierecoach']")
    end

    test "stays when it cannot be saved, and leaves unsaved when chosen again", %{
      conn: conn,
      profile: profile
    } do
      component = "intro-translations-#{profile.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      choose(view, component, "de")
      draft(view, component, %{"headline" => "Karrierecoach"})
      # Another tab removes German meanwhile.
      profile |> Changeset.change(translation_locales: ["fr"]) |> Repo.update!()

      choose(view, component, "en")

      assert has_element?(view, "##{component}-editor input[value='Karrierecoach']")
      assert render(view) =~ "Choose the language again to leave without saving them."

      choose(view, component, "en")

      refute has_element?(view, "##{component}-editor")
      assert stored(Repo.reload!(profile), "de", "headline") == nil
    end
  end

  test "saving in a language removed in another tab shows the translated error", %{
    conn: conn,
    profile: profile
  } do
    component = "intro-translations-#{profile.id}"
    conn = init_test_session(conn, %{chosen_locale: "pl"})
    {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

    choose(view, component, "de")
    profile |> Changeset.change(translation_locales: ["fr"]) |> Repo.update!()
    translate(view, component, %{"headline" => "Karrierecoach"})

    assert view |> element("##{component}-editor .form-field-error") |> render() =~
             "nie jest językiem tłumaczenia"

    assert stored(Repo.reload!(profile), "de", "headline") == nil
  end
end
