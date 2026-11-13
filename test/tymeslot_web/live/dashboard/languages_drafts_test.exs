defmodule TymeslotWeb.Dashboard.LanguagesDraftsTest do
  @moduledoc """
  What is typed on the Languages review page is never dropped without
  saying so: leaving or filtering the page saves every open editor, and an
  editor whose save fails stays until asked again. Also: an outdated
  translation can be kept as still correct, and the remove-language dialog
  says what removing means for the languages offered.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :i18n
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup %{profile: profile} do
    RateLimiter.clear_all()

    profile =
      profile
      |> Changeset.change(
        username: "lingo-drafts",
        translation_locales: ["de", "fr"],
        headline: "Career coach",
        bio: "I help new managers."
      )
      |> Repo.update!()

    %{profile: profile}
  end

  # A click starts a chain of `send_update`s (each editor's save, then the
  # page's own step), each handled after the one before: every synchronous
  # call waits out one more link.
  defp settle(view) do
    for _link <- 1..5, do: :sys.get_state(view.pid)
    :ok
  end

  defp meeting_type_translation(meeting_type, user, path) do
    meeting_type.id
    |> MeetingTypes.get_meeting_type(user.id)
    |> ContentTranslations.translation("de", path)
  end

  describe "the Languages review page" do
    setup %{user: user} do
      %{meeting_type: insert(:meeting_type, user: user, name: "Intro call", description: nil)}
    end

    test "All languages saves what was typed before leaving", %{
      conn: conn,
      user: user,
      meeting_type: meeting_type
    } do
      component = "translation-meeting_types-meeting_type-#{meeting_type.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")

      view
      |> form("##{component}-form", %{"translation" => %{"name" => "Erstgespräch"}})
      |> render_change()

      view |> element("[data-testid='all-languages']") |> render_click()

      assert_patch(view, ~p"/dashboard/languages")
      assert meeting_type_translation(meeting_type, user, "name") == "Erstgespräch"
    end

    test "Only missing or outdated saves what was typed before filtering", %{
      conn: conn,
      user: user,
      meeting_type: meeting_type
    } do
      component = "translation-meeting_types-meeting_type-#{meeting_type.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")

      view
      |> form("##{component}-form", %{"translation" => %{"name" => "Erstgespräch"}})
      |> render_change()

      view |> element("#only-open-translations") |> render_click()
      settle(view)

      assert meeting_type_translation(meeting_type, user, "name") == "Erstgespräch"
      assert has_element?(view, "#only-open-translations[aria-checked='true']")
      refute has_element?(view, "##{component}")
    end

    test "All languages stays when what was typed cannot be saved, and leaves when asked again",
         %{conn: conn, user: user, profile: profile, meeting_type: meeting_type} do
      component = "translation-meeting_types-meeting_type-#{meeting_type.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")

      view
      |> form("##{component}-form", %{"translation" => %{"name" => "Erstgespräch"}})
      |> render_change()

      # Another tab removes German meanwhile.
      profile |> Changeset.change(translation_locales: ["fr"]) |> Repo.update!()

      view |> element("[data-testid='all-languages']") |> render_click()
      settle(view)

      assert has_element?(view, "##{component}-form input[value='Erstgespräch']")
      assert render(view) =~ "Try again to leave without saving them."

      view |> element("[data-testid='all-languages']") |> render_click()
      settle(view)

      assert_patch(view, ~p"/dashboard/languages")
      assert meeting_type_translation(meeting_type, user, "name") == nil
    end
  end

  describe "an outdated translation" do
    test "is kept as still correct, and counts as translated again", %{
      conn: conn,
      user: user
    } do
      meeting_type = insert(:meeting_type, user: user, name: "Intro call", description: nil)

      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{"name" => "Gespräch"})

      meeting_type |> Changeset.change(name: "First call") |> Repo.update!()

      component = "translation-meeting_types-meeting_type-#{meeting_type.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")

      assert has_element?(view, "##{component} [data-path='name'][data-status='outdated']")

      assert view |> element("##{component} [data-path='name']") |> render() =~
               "Invitees see the original until you update this translation"

      view
      |> element("##{component} [data-path='name'] [data-testid='confirm-translation']")
      |> render_click()

      assert has_element?(view, "##{component} [data-path='name'][data-status='translated']")
      refute has_element?(view, "##{component} [data-testid='confirm-translation']")

      stored = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
      assert ContentTranslations.status(stored, "name", "de") == :translated
      assert ContentTranslations.translation(stored, "de", "name") == "Gespräch"
    end

    test "is not offered to keep once something else is typed over it", %{
      conn: conn,
      user: user
    } do
      meeting_type = insert(:meeting_type, user: user, name: "Intro call", description: nil)

      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{"name" => "Gespräch"})

      meeting_type |> Changeset.change(name: "First call") |> Repo.update!()

      component = "translation-meeting_types-meeting_type-#{meeting_type.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")

      view
      |> form("##{component}-form", %{"translation" => %{"name" => "Erstes Gespräch"}})
      |> render_change()

      refute has_element?(view, "##{component} [data-testid='confirm-translation']")
    end
  end

  describe "the remove-language dialog" do
    test "says the language is no longer offered when only chosen ones are", %{
      conn: conn,
      profile: profile
    } do
      profile |> Changeset.change(offer_all_locales: false) |> Repo.update!()
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      view |> element("[data-testid='remove-locale-de']") |> render_click()

      assert view |> element("[data-testid='remove-language-effect']") |> render() =~
               "will no longer be offered in Deutsch"
    end

    test "says invitees can still choose it, in the original, when all are offered", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

      view |> element("[data-testid='remove-locale-de']") |> render_click()

      assert view |> element("[data-testid='remove-language-effect']") |> render() =~
               "invitees can still choose Deutsch, but they will see your texts in English"
    end
  end
end
