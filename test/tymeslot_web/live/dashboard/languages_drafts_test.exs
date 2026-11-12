defmodule TymeslotWeb.Dashboard.LanguagesDraftsTest do
  @moduledoc """
  What is typed under a language bar is never dropped without saying so:
  closing the meeting type editor or the venue modal saves a translation
  typed in it, leaving the original of a form saved by hand saves the
  original first, and leaving or filtering the Languages review page saves
  every open editor. Also: an outdated translation can be kept as still
  correct, the editor shows a translation saved elsewhere, a click on the
  language bar does not reload the meeting settings, and the remove-language
  dialog says what removing means for the languages offered.
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
  alias Tymeslot.Venues.VenueSchema

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

  # A click starts a chain of `send_update`s and messages (the bar, the
  # editor's save, the host's close or the dashboard's switch), each handled
  # after the one before: every synchronous call waits out one more link.
  defp settle(view) do
    for _link <- 1..5, do: :sys.get_state(view.pid)
    :ok
  end

  defp choose(view, component, locale) do
    view |> element("##{component}-bar-#{locale}") |> render_click()
    settle(view)
  end

  defp draft(view, component, texts),
    do: view |> form("##{component}-editor-form", %{"translation" => texts}) |> render_change()

  defp meeting_type_translation(meeting_type, user, path) do
    meeting_type.id
    |> MeetingTypes.get_meeting_type(user.id)
    |> ContentTranslations.translation("de", path)
  end

  defp open_meeting_type(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  describe "closing a form with a translation typed and not saved" do
    test "Done on the meeting type editor saves it, then closes", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Intro call")
      component = "meeting-type-translations-#{meeting_type.id}"
      view = open_meeting_type(conn, meeting_type)

      choose(view, component, "de")
      draft(view, component, %{"name" => "Erstgespräch"})

      view |> element("##{component} button[phx-click='close_edit_overlay']") |> render_click()
      settle(view)

      assert meeting_type_translation(meeting_type, user, "name") == "Erstgespräch"
      refute has_element?(view, "#meeting-type-config-view")
    end

    test "the meeting type editor's close button saves it too", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Intro call")
      component = "meeting-type-translations-#{meeting_type.id}"
      view = open_meeting_type(conn, meeting_type)

      choose(view, component, "de")
      draft(view, component, %{"name" => "Erstgespräch"})

      view
      |> element("#meeting-type-config-view button[aria-label='Close']")
      |> render_click()

      settle(view)

      assert meeting_type_translation(meeting_type, user, "name") == "Erstgespräch"
      refute has_element?(view, "#meeting-type-config-view")
    end

    test "closing the venue modal saves it, then closes", %{conn: conn, user: user} do
      venue = insert(:venue, user: user, name: "Studio")
      component = "venue-translations-#{venue.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/locations")

      view |> element("[phx-click='edit_venue'][phx-value-id='#{venue.id}']") |> render_click()
      choose(view, component, "de")
      draft(view, component, %{"name" => "Atelier"})

      view |> element("##{component} button[phx-click='close_venue_form']") |> render_click()
      settle(view)

      saved = Repo.get!(VenueSchema, venue.id)
      assert ContentTranslations.translation(saved, "de", "name") == "Atelier"
      refute has_element?(view, "#venue-form-modal")
    end
  end

  describe "leaving the original of a form saved by hand" do
    test "the intro saves what was typed, and the editor shows it as the original", %{
      conn: conn,
      profile: profile
    } do
      component = "intro-translations-#{profile.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#intro-form", profile_intro: %{headline: "Leadership coach", bio: "Still here."})
      |> render_change()

      choose(view, component, "de")

      assert Repo.reload!(profile).headline == "Leadership coach"

      assert view |> element("##{component}-editor [data-path='headline']") |> render() =~
               "Original: Leadership coach"
    end

    test "the intro stays on the original when what was typed cannot be saved", %{
      conn: conn,
      profile: profile
    } do
      component = "intro-translations-#{profile.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#intro-form", profile_intro: %{headline: String.duplicate("a", 500)})
      |> render_change()

      choose(view, component, "de")

      assert Repo.reload!(profile).headline == "Career coach"
      refute has_element?(view, "##{component}-editor")
      assert has_element?(view, "#intro-form .form-field-error")
    end

    test "the venue modal saves what was typed, and stays open on it", %{
      conn: conn,
      user: user
    } do
      venue = insert(:venue, user: user, name: "Studio")
      component = "venue-translations-#{venue.id}"
      {:ok, view, _html} = live(conn, ~p"/dashboard/locations")

      view |> element("[phx-click='edit_venue'][phx-value-id='#{venue.id}']") |> render_click()

      view
      |> form("#venue-form", %{"venue" => %{"name" => "Main studio"}})
      |> render_change()

      choose(view, component, "de")

      assert Repo.get!(VenueSchema, venue.id).name == "Main studio"

      assert view |> element("##{component}-editor [data-path='name']") |> render() =~
               "Original: Main studio"
    end
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

  test "the editor shows a translation saved elsewhere since the form opened", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    component = "intro-translations-#{profile.id}"
    {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

    # Saved from another tab while this one shows the original.
    {:ok, _entity} =
      Catalogue.save(user.id, {:profile, profile.id}, "de", %{"headline" => "Coach"})

    choose(view, component, "de")

    assert has_element?(view, "##{component}-editor input[value='Coach']")

    assert has_element?(
             view,
             "##{component}-editor [data-path='headline'][data-status='translated']"
           )
  end

  test "a click on the language bar does not reload the meeting settings", %{
    conn: conn,
    user: user
  } do
    meeting_type = insert(:meeting_type, user: user, name: "Intro call")
    view = open_meeting_type(conn, meeting_type)
    test_pid = self()
    handler = "language-bar-queries-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, metadata, {pid, live} ->
          if self() == live, do: send(pid, {:query, metadata.source})
        end,
        {test_pid, view.pid}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    choose(view, "meeting-type-translations-#{meeting_type.id}", "de")
    assert has_element?(view, "#meeting-type-translations-#{meeting_type.id}-editor")

    # The editor reads its record's translations again (`meeting_types`),
    # but nothing the section lists is read.
    sources = collect_sources([])
    assert "meeting_types" in sources
    refute "video_integrations" in sources
    refute "calendar_integrations" in sources
    refute "venues" in sources
  end

  defp collect_sources(acc) do
    receive do
      {:query, source} -> collect_sources([source | acc])
    after
      0 -> acc
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
