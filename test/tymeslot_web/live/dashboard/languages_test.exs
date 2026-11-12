defmodule TymeslotWeb.Dashboard.LanguagesTest do
  @moduledoc """
  The Languages page and the language bar: choosing the booking languages,
  removing one through its confirmation, translating on the review page, and
  translating a meeting type from its own editor, with the editing language
  carried between dashboard pages.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :i18n
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.CustomFields.FieldOption
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo

  setup :setup_dashboard_user

  defp with_languages(profile, attrs), do: Repo.update!(Changeset.change(profile, attrs))

  defp meeting_type_with_question(user) do
    insert(:meeting_type,
      user: user,
      name: "Intro call",
      description: nil,
      custom_fields: [
        %FieldDefinition{id: "q1", type: "short_text", label: "Company", position: 0}
      ]
    )
  end

  defp stored_translation(meeting_type, user, path) do
    meeting_type.id
    |> MeetingTypes.get_meeting_type(user.id)
    |> ContentTranslations.translation("de", path)
  end

  describe "the settings" do
    test "adding a translation language and showing only the own languages persist", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      view |> element("#add-language-form") |> render_change(%{"locale" => "de"})

      assert Repo.reload!(profile).translation_locales == ["de"]
      assert has_element?(view, "[data-testid='translation-languages'] li[data-locale='de']")

      view |> element("#offer-all-locales") |> render_click()

      reloaded = Repo.reload!(profile)
      assert reloaded.offer_all_locales == false
      assert reloaded.translation_locales == ["de"]
      assert render(view) =~ "offered only in English and your translation languages"
    end

    test "with all languages off and no translations, says only the original is offered", %{
      conn: conn,
      profile: profile
    } do
      with_languages(profile, offer_all_locales: false)

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      assert render(view) =~ "visitors see no language switcher"
    end

    test "removing a language asks first, and keeps its translations", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      with_languages(profile, translation_locales: ["de", "fr"])
      meeting_type = meeting_type_with_question(user)

      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "name" => "Erstgespräch"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      view |> element("[data-testid='remove-locale-de']") |> render_click()

      assert has_element?(view, "#remove-language-modal")
      assert Repo.reload!(profile).translation_locales == ["de", "fr"]

      view |> element("[data-testid='confirm-remove-language']") |> render_click()

      assert Repo.reload!(profile).translation_locales == ["fr"]
      refute has_element?(view, "#remove-language-modal")
      refute has_element?(view, "[data-testid='translation-languages'] li[data-locale='de']")
      assert stored_translation(meeting_type, user, "name") == "Erstgespräch"
    end

    test "cancelling the removal keeps the language", %{conn: conn, profile: profile} do
      with_languages(profile, translation_locales: ["de"])

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      view |> element("[data-testid='remove-locale-de']") |> render_click()
      view |> element("#remove-language-modal button", "Cancel") |> render_click()

      refute has_element?(view, "#remove-language-modal")
      assert Repo.reload!(profile).translation_locales == ["de"]
    end

    test "shows each language's progress", %{conn: conn, user: user, profile: profile} do
      with_languages(profile, translation_locales: ["de"])
      meeting_type = meeting_type_with_question(user)

      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "name" => "Erstgespräch"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      assert view
             |> element("li[data-locale='de'] [data-testid='translation-progress']")
             |> render() =~
               "1/2 translated"
    end
  end

  describe "the review page" do
    setup %{user: user, profile: profile} do
      with_languages(profile, translation_locales: ["de"])
      %{meeting_type: meeting_type_with_question(user)}
    end

    test "saves a meeting type's name and question label, which then show as Translated", %{
      conn: conn,
      user: user,
      meeting_type: meeting_type
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")
      editor = "#translation-meeting_types-meeting_type-#{meeting_type.id}"

      assert has_element?(view, "#{editor} [data-path='name'][data-status='missing']")

      assert has_element?(
               view,
               "#{editor} [data-path='custom_fields/q1/label'][data-status='missing']"
             )

      view
      |> form("#{editor}-form", %{
        "translation" => %{"name" => "Erstgespräch", "custom_fields/q1/label" => "Firma"}
      })
      |> render_submit()

      assert stored_translation(meeting_type, user, "name") == "Erstgespräch"
      assert stored_translation(meeting_type, user, "custom_fields/q1/label") == "Firma"
      assert has_element?(view, "#{editor} [data-path='name'][data-status='translated']")

      assert has_element?(
               view,
               "#{editor} [data-path='custom_fields/q1/label'][data-status='translated']"
             )
    end

    test "names the question an option belongs to", %{conn: conn, user: user} do
      choice =
        insert(:meeting_type,
          user: user,
          name: "Workshop",
          custom_fields: [
            %FieldDefinition{
              id: "q2",
              type: "single_choice",
              label: "Team size",
              position: 0,
              options: [
                %FieldOption{key: "small", label: "Small"},
                %FieldOption{key: "large", label: "Large"}
              ]
            }
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")

      assert view
             |> element(
               "#translation-meeting_types-meeting_type-#{choice.id} [data-path='custom_fields/q2/options/small/label']"
             )
             |> render() =~ "Answer option (Team size)"
    end

    test "shows a text over its cap inline and saves nothing", %{
      conn: conn,
      user: user,
      meeting_type: meeting_type
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")
      editor = "#translation-meeting_types-meeting_type-#{meeting_type.id}"

      view
      |> element("#{editor}-form")
      |> render_submit(%{
        "translation" => %{"custom_fields/q1/label" => String.duplicate("a", 121)}
      })

      assert has_element?(
               view,
               "#{editor} [data-path='custom_fields/q1/label'] .form-field-error"
             )

      refute has_element?(view, "#{editor} [data-path='name'] .form-field-error")

      # The review page's language is what is being translated, not the
      # dashboard's: the message stays in the organiser's own language.
      assert view |> element("#{editor} [data-path='custom_fields/q1/label']") |> render() =~
               "at most"

      assert stored_translation(meeting_type, user, "custom_fields/q1/label") == nil
    end

    test "only missing or outdated hides what is translated", %{
      conn: conn,
      user: user,
      meeting_type: meeting_type
    } do
      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "name" => "Erstgespräch"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")
      editor = "#translation-meeting_types-meeting_type-#{meeting_type.id}"
      assert has_element?(view, "#{editor} [data-path='name']")

      view |> element("#only-open-translations") |> render_click()

      refute has_element?(view, "#{editor} [data-path='name']")
      assert has_element?(view, "#{editor} [data-path='custom_fields/q1/label']")
    end

    test "a language that is not a translation language goes back to the settings", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/fr")

      assert_patch(view, ~p"/dashboard/languages")
    end
  end

  describe "the language bar on the meeting type editor" do
    setup %{conn: conn, user: user, profile: profile} do
      with_languages(profile, translation_locales: ["de"])
      meeting_type = meeting_type_with_question(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      %{
        view: view,
        meeting_type: meeting_type,
        bar: "#meeting-type-translations-#{meeting_type.id}"
      }
    end

    test "swaps the form for the translation editor, which saves", %{
      view: view,
      user: user,
      meeting_type: meeting_type,
      bar: bar
    } do
      refute has_element?(view, "#{bar}-editor")

      view |> element("#{bar}-bar button[data-locale='de']") |> render_click()

      assert has_element?(view, "#{bar}-editor")
      assert has_element?(view, "form[id^='meeting-type-form-'].hidden")

      view
      |> form("#{bar}-editor-form", %{"translation" => %{"name" => "Erstgespräch"}})
      |> render_submit()

      assert stored_translation(meeting_type, user, "name") == "Erstgespräch"
      assert has_element?(view, "#{bar}-editor [data-path='name'][data-status='translated']")

      view |> element("#{bar}-bar button[data-locale='en']") |> render_click()

      refute has_element?(view, "#{bar}-editor")
      refute has_element?(view, "form[id^='meeting-type-form-'].hidden")
    end

    test "keeps the editing language on another dashboard page", %{
      conn: _conn,
      view: view,
      profile: profile,
      bar: bar
    } do
      view |> element("#{bar}-bar button[data-locale='de']") |> render_click()

      render_patch(view, ~p"/dashboard/settings")

      assert has_element?(view, "#intro-translations-#{profile.id}-editor")
      refute has_element?(view, "#intro-form")
    end

    test "an original edit's autosave keeps the stored translation", %{
      view: view,
      user: user,
      meeting_type: meeting_type
    } do
      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "name" => "Erstgespräch"
        })

      view
      |> element(~s|input[name="meeting_type[name]"]|)
      |> render_change(%{"meeting_type" => %{"name" => "First call"}})

      reloaded = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
      assert reloaded.name == "First call"
      assert ContentTranslations.translation(reloaded, "de", "name") == "Erstgespräch"
      assert ContentTranslations.status(reloaded, "name", "de") == :outdated
    end
  end

  test "without a translation language there is no language bar", %{conn: conn, user: user} do
    meeting_type = meeting_type_with_question(user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    refute has_element?(view, "[data-testid='language-bar']")
    assert has_element?(view, ~s|input[name="meeting_type[name]"]|)
  end
end
