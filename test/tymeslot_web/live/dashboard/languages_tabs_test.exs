defmodule TymeslotWeb.Dashboard.LanguagesTabsTest do
  @moduledoc """
  The Languages page's two tabs: picking the original language and the
  booking languages on Settings, and moving between Settings, the
  Translations tab and its languages, where each text shows its original
  beside the box for its translation.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :i18n
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.Locales
  alias Tymeslot.Repo

  setup :setup_dashboard_user

  defp with_languages(profile, attrs), do: Repo.update!(Changeset.change(profile, attrs))

  describe "Settings" do
    test "lists every supported language, the original ticked and locked", %{
      conn: conn,
      profile: profile
    } do
      with_languages(profile,
        content_locale: "en",
        translation_locales: ["de"],
        offer_all_locales: false
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      for code <- Locales.supported_codes(),
          do:
            assert(
              has_element?(view, "[data-testid='booking-languages'] li[data-locale='#{code}']")
            )

      assert has_element?(view, "#language-en[disabled][checked]")
      assert view |> element("li[data-locale='en']") |> render() =~ "Original"
      refute has_element?(view, "[data-testid='make-original-en']")
      assert has_element?(view, "#language-de[checked]")
      refute has_element?(view, "#language-fr[checked]")
      refute has_element?(view, "[data-testid='translate-de'][aria-hidden]")
      assert has_element?(view, "[data-testid='translate-fr'][aria-hidden='true']")
    end

    test "with every language offered, each can be translated", %{
      conn: conn,
      profile: profile
    } do
      with_languages(profile, content_locale: "en", translation_locales: [])
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      for code <- Locales.supported_codes() -- ["en"],
          do: refute(has_element?(view, "[data-testid='translate-#{code}'][aria-hidden]"))
    end

    test "Make original sets only the original, whichever languages are offered", %{
      conn: conn,
      profile: profile
    } do
      with_languages(profile, content_locale: "en", translation_locales: ["de"])
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      view |> element("[data-testid='make-original-fr']") |> render_click()

      reloaded = Repo.reload!(profile)
      assert reloaded.content_locale == "fr"
      assert reloaded.translation_locales == ["de"]
      assert reloaded.offer_all_locales == true
      refute has_element?(view, "[data-testid='make-original-fr']")
      assert has_element?(view, "[data-testid='make-original-en']")
      assert view |> element("li[data-locale='fr']") |> render() =~ "Original"
    end

    test "unticking shows the box unticked while it asks, and ticked again on cancel", %{
      conn: conn,
      profile: profile
    } do
      with_languages(profile, translation_locales: ["de"], offer_all_locales: false)
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      view |> element("#language-de") |> render_click()
      assert has_element?(view, "#remove-language-modal")
      refute has_element?(view, "#language-de[checked]")

      view |> element("#remove-language-modal button", "Cancel") |> render_click()
      assert has_element?(view, "#language-de[checked]")
    end
  end

  describe "the tabs" do
    test "offering only the original, the Translations tab is disabled and says why", %{
      conn: conn,
      profile: profile
    } do
      with_languages(profile, translation_locales: [], offer_all_locales: false)
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      assert has_element?(
               view,
               "#languages-tabs-tab-translations[disabled][aria-describedby='translations-tab-hint']"
             )

      assert has_element?(view, "#translations-tab-hint")
    end

    test "Translations opens the language with the most left to translate", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      with_languages(profile, translation_locales: ["de", "fr"])
      meeting_type = insert(:meeting_type, user: user, name: "Intro call", description: nil)

      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "name" => "Erstgespräch"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      view |> element("#languages-tabs-tab-translations") |> render_click()
      assert_patch(view, ~p"/dashboard/languages/fr")
    end

    test "offering every language with none chosen, Translations opens the first of them", %{
      conn: conn,
      profile: profile
    } do
      with_languages(profile, content_locale: "en", translation_locales: [])
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      view |> element("#languages-tabs-tab-translations") |> render_click()
      [first | _rest] = Locales.supported_codes() -- ["en"]
      assert_patch(view, ~p"/dashboard/languages/#{first}")
    end

    test "offering every language, each has a tab, but only chosen ones show what is left", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      with_languages(profile, content_locale: "en", translation_locales: ["de"])
      insert(:meeting_type, user: user, name: "Intro call", description: nil)

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")

      for code <- Locales.supported_codes() -- ["en"],
          do: assert(has_element?(view, "#translation-language-tabs-tab-#{code}"))

      refute has_element?(view, "#translation-language-tabs-tab-en")
      assert view |> element("#translation-language-tabs-tab-de") |> render() =~ "to translate"
      refute view |> element("#translation-language-tabs-tab-fr") |> render() =~ "to translate"
    end

    test "a language tab switches language, and Settings goes back", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      with_languages(profile, translation_locales: ["de", "fr"])
      insert(:meeting_type, user: user, name: "Intro call", description: nil)

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")

      assert has_element?(view, "#languages-tabs-tab-translations[aria-selected='true']")
      assert has_element?(view, "#translation-language-tabs-tab-de[aria-selected='true']")

      view |> element("#translation-language-tabs-tab-fr") |> render_click()
      assert_patch(view, ~p"/dashboard/languages/fr")

      view |> element("#languages-tabs-tab-settings") |> render_click()
      assert_patch(view, ~p"/dashboard/languages")
    end

    test "each text shows its original beside the box for its translation", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      with_languages(profile, translation_locales: ["de"])
      meeting_type = insert(:meeting_type, user: user, name: "Intro call", description: nil)

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")
      field = "#translation-meeting_types-meeting_type-#{meeting_type.id} [data-path='name']"

      assert view |> element("#{field} [data-testid='original-text']") |> render() =~ "Intro call"
      assert has_element?(view, "#{field} input[placeholder='Type the Deutsch version']")
      assert has_element?(view, "[data-testid='translate-instruction']")
    end
  end
end
