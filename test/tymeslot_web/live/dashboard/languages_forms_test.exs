defmodule TymeslotWeb.Dashboard.LanguagesFormsTest do
  @moduledoc """
  The forms that edit translatable texts (the meeting type editor, the
  booking page text card, the profile intro and the venue modal) say how
  their texts stand in the translation languages, and send the organiser to
  the Languages page to translate them: a strip naming the languages the
  booking page offers, how many texts are translated and a link to the
  record on the review page, and a globe on each translatable field with a
  chip for each language it is missing or outdated in.

  Translating happens on the review page only: each kind of record saves
  its translation there apart from the original, which its own form then
  saves without touching the translation. Also the whole journey: an
  original changed in the editor shows as outdated, the link leads to the
  review page, and the chip is gone once the translation is updated.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :i18n
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.CustomFields.FieldDefinition
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

  defp stored(record, locale, path), do: ContentTranslations.translation(record, locale, path)

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp chip(locale, status),
    do: "[data-testid='translation-chip'][data-locale='#{locale}'][data-status='#{status}']"

  defp mark(path), do: "[data-testid='translation-mark'][data-path='#{path}']"

  defp open_meeting_type(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  describe "the meeting type editor" do
    setup %{user: user} do
      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Intro call",
          description: "A first chat.",
          custom_fields: [
            %FieldDefinition{id: "q1", type: "short_text", label: "Company", position: 0}
          ]
        )

      %{meeting_type: meeting_type}
    end

    test "names every language when the booking page offers them all", %{
      conn: conn,
      meeting_type: meeting_type
    } do
      view = open_meeting_type(conn, meeting_type)

      assert text(view, "[data-testid='translation-strip-languages']") ==
               "Booking page in every language; your texts are translated into Deutsch, Français."
    end

    test "names the original and the translation languages when only those are offered", %{
      conn: conn,
      profile: profile,
      meeting_type: meeting_type
    } do
      profile |> Changeset.change(offer_all_locales: false) |> Repo.update!()
      view = open_meeting_type(conn, meeting_type)

      assert text(view, "[data-testid='translation-strip-languages']") ==
               "Booking page in English (original), Deutsch, Français."
    end

    test "counts the texts translated into every language", %{
      conn: conn,
      user: user,
      meeting_type: meeting_type
    } do
      for locale <- ["de", "fr"] do
        {:ok, _entity} =
          Catalogue.save(user.id, {:meeting_type, meeting_type.id}, locale, %{"name" => "Call"})
      end

      # Translated into one language only, so not done.
      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "description" => "Ein erstes Gespräch."
        })

      view = open_meeting_type(conn, meeting_type)

      assert text(view, "[data-testid='translation-strip-progress']") ==
               "Texts marked globe are translatable: 1 of 3 done."
    end

    test "links to the language with the most texts left, at this meeting type", %{
      conn: conn,
      user: user,
      meeting_type: meeting_type
    } do
      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{"name" => "Gespräch"})

      view = open_meeting_type(conn, meeting_type)
      anchor = "translate-meeting_types-meeting_type-#{meeting_type.id}"

      assert has_element?(
               view,
               "[data-testid='translation-strip-link'][href='/dashboard/languages/fr?item=#{anchor}##{anchor}']"
             )
    end

    test "marks each translatable field, with a chip per language missing or outdated", %{
      conn: conn,
      user: user,
      meeting_type: meeting_type
    } do
      for locale <- ["de", "fr"] do
        {:ok, _entity} =
          Catalogue.save(user.id, {:meeting_type, meeting_type.id}, locale, %{"name" => "Call"})
      end

      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "description" => "Ein erstes Gespräch."
        })

      # French's description was written against an earlier original.
      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "fr", %{
          "description" => "Une discussion."
        })

      meeting_type |> Changeset.change(description: "A first talk.") |> Repo.update!()

      view = open_meeting_type(conn, meeting_type)

      assert has_element?(view, mark("name"))
      refute has_element?(view, "#{mark("name")} [data-testid='translation-chip']")

      assert has_element?(view, "#{mark("description")} #{chip("de", "outdated")}")
      assert has_element?(view, "#{mark("description")} #{chip("fr", "outdated")}")

      assert text(view, "#{mark("description")} #{chip("fr", "outdated")}") ==
               "Français: outdated"

      assert has_element?(view, "#{mark("custom_fields/")} #{chip("de", "missing")}")

      assert text(view, "#{mark("custom_fields/")} #{chip("de", "missing")}") ==
               "Deutsch: missing"
    end

    test "saving the original keeps the stored translation, now outdated", %{
      conn: conn,
      user: user,
      meeting_type: meeting_type
    } do
      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{"name" => "Gespräch"})

      view = open_meeting_type(conn, meeting_type)

      view
      |> element(~s|input[name="meeting_type[name]"]|)
      |> render_change(%{"meeting_type" => %{"name" => "First call"}})

      reloaded = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
      assert reloaded.name == "First call"
      assert stored(reloaded, "de", "name") == "Gespräch"
      assert has_element?(view, "#{mark("name")} #{chip("de", "outdated")}")
    end
  end

  describe "the booking page text card" do
    test "shows the strip and marks, and links to the booking page texts", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/pages")
      anchor = "translate-booking_texts-profile-#{profile.id}"

      assert text(view, "[data-testid='translation-strip-progress']") ==
               "Texts marked globe are translatable: 0 of 3 done."

      assert has_element?(view, "[data-testid='translation-strip-link'][href$='##{anchor}']")
      assert has_element?(view, "#{mark("booking_heading")} #{chip("de", "missing")}")
    end

    test "translated on the Languages page, apart from the original, which an autosave keeps",
         %{conn: conn, profile: profile} do
      {:ok, review, _html} = live(conn, ~p"/dashboard/languages/de")

      review
      |> form("#translation-booking_texts-profile-#{profile.id}-form", %{
        "translation" => %{"booking_heading" => "Bereit zu reden?"}
      })
      |> render_submit()

      saved = Repo.reload!(profile)
      assert stored(saved, "de", "booking_heading") == "Bereit zu reden?"
      assert saved.booking_heading == "Ready to talk?"

      {:ok, view, _html} = live(conn, ~p"/dashboard/pages")
      refute has_element?(view, "#{mark("booking_heading")} #{chip("de", "missing")}")
      assert has_element?(view, "#{mark("booking_heading")} #{chip("fr", "missing")}")

      view
      |> form("#booking-text-form-form", profile_schema: %{booking_heading: "Shall we talk?"})
      |> render_change()

      saved = Repo.reload!(profile)
      assert saved.booking_heading == "Shall we talk?"
      assert stored(saved, "de", "booking_heading") == "Bereit zu reden?"
      assert has_element?(view, "#{mark("booking_heading")} #{chip("de", "outdated")}")
    end
  end

  describe "the profile intro" do
    test "shows the strip and marks, and links to the headline and bio", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")
      anchor = "translate-intro-profile-#{profile.id}"

      assert text(view, "#intro-form-container [data-testid='translation-strip-progress']") ==
               "Texts marked globe are translatable: 0 of 2 done."

      assert has_element?(
               view,
               "#intro-form-container [data-testid='translation-strip-link'][href='/dashboard/languages/de?item=#{anchor}##{anchor}']"
             )

      assert has_element?(view, "#{mark("headline")} #{chip("de", "missing")}")
      assert has_element?(view, "#{mark("bio")} #{chip("fr", "missing")}")
    end

    test "translated on the Languages page, apart from the original, which a later save keeps",
         %{conn: conn, profile: profile} do
      {:ok, review, _html} = live(conn, ~p"/dashboard/languages/de")

      review
      |> form("#translation-intro-profile-#{profile.id}-form", %{
        "translation" => %{"headline" => "Karrierecoach"}
      })
      |> render_submit()

      saved = Repo.reload!(profile)
      assert stored(saved, "de", "headline") == "Karrierecoach"
      assert saved.headline == "Career coach"

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#intro-form", profile_intro: %{headline: "Leadership coach", bio: "Still here."})
      |> render_submit()

      saved = Repo.reload!(profile)
      assert saved.headline == "Leadership coach"
      assert stored(saved, "de", "headline") == "Karrierecoach"
      assert has_element?(view, "#{mark("headline")} #{chip("de", "outdated")}")
    end
  end

  describe "the venue modal" do
    test "shows the strip and marks when editing, and none when adding", %{
      conn: conn,
      user: user
    } do
      venue = insert(:venue, user: user, name: "Studio", description: "Old Street 1")
      {:ok, view, _html} = live(conn, ~p"/dashboard/locations")

      view |> element("[data-testid='add-venue']") |> render_click()
      refute has_element?(view, "#venue-form-modal [data-testid='translation-strip']")
      refute has_element?(view, "#venue-form-modal [data-testid='translation-mark']")
      view |> element("#venue-form button[phx-click='close_venue_form']") |> render_click()

      view |> element("[phx-click='edit_venue'][phx-value-id='#{venue.id}']") |> render_click()
      anchor = "translate-venues-venue-#{venue.id}"

      assert has_element?(
               view,
               "#venue-form-modal [data-testid='translation-strip-link'][href$='##{anchor}']"
             )

      assert has_element?(view, "#venue-form-modal #{mark("name")} #{chip("de", "missing")}")
    end

    test "translated on the Languages page, apart from the original, which a later save keeps",
         %{conn: conn, user: user} do
      venue = insert(:venue, user: user, name: "Studio", description: "Old Street 1")
      {:ok, review, _html} = live(conn, ~p"/dashboard/languages/de")

      review
      |> form("#translation-venues-venue-#{venue.id}-form", %{
        "translation" => %{"name" => "Atelier"}
      })
      |> render_submit()

      saved = Repo.get!(VenueSchema, venue.id)
      assert stored(saved, "de", "name") == "Atelier"
      assert saved.name == "Studio"

      {:ok, view, _html} = live(conn, ~p"/dashboard/locations")
      view |> element("[phx-click='edit_venue'][phx-value-id='#{venue.id}']") |> render_click()

      view
      |> form("#venue-form", %{"venue" => %{"name" => "Main studio"}})
      |> render_submit()

      saved = Repo.get!(VenueSchema, venue.id)
      assert saved.name == "Main studio"
      assert stored(saved, "de", "name") == "Atelier"
    end
  end

  test "saving on the review page in a language removed in another tab shows the translated error",
       %{conn: conn, profile: profile} do
    conn = init_test_session(conn, %{chosen_locale: "pl"})
    {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")
    editor = "#translation-intro-profile-#{profile.id}"

    profile |> Changeset.change(translation_locales: ["fr"]) |> Repo.update!()

    view
    |> form("#{editor}-form", %{"translation" => %{"headline" => "Karrierecoach"}})
    |> render_submit()

    assert view |> element("#{editor} .form-field-error") |> render() =~
             "nie jest językiem tłumaczenia"

    assert stored(Repo.reload!(profile), "de", "headline") == nil
  end

  @tag :integration
  test "an original edited in the editor is outdated, until updated on the Languages page", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    profile |> Changeset.change(translation_locales: ["de"]) |> Repo.update!()
    meeting_type = insert(:meeting_type, user: user, name: "Intro call", description: nil)

    {:ok, _entity} =
      Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{"name" => "Gespräch"})

    view = open_meeting_type(conn, meeting_type)
    refute has_element?(view, "#{mark("name")} [data-testid='translation-chip']")

    view
    |> element(~s|input[name="meeting_type[name]"]|)
    |> render_change(%{"meeting_type" => %{"name" => "First call"}})

    assert text(view, "#{mark("name")} #{chip("de", "outdated")}") == "Deutsch: outdated"

    view |> element("[data-testid='translation-strip-link']") |> render_click()
    anchor = "translate-meeting_types-meeting_type-#{meeting_type.id}"
    assert_patch(view, "/dashboard/languages/de?item=#{anchor}")

    assert has_element?(
             view,
             "##{anchor}[data-highlighted] [data-path='name'][data-status='outdated']"
           )

    view
    |> form("#translation-meeting_types-meeting_type-#{meeting_type.id}-form", %{
      "translation" => %{"name" => "Erstes Gespräch"}
    })
    |> render_submit()

    assert stored(MeetingTypes.get_meeting_type(meeting_type.id, user.id), "de", "name") ==
             "Erstes Gespräch"

    render_patch(view, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    assert has_element?(view, mark("name"))
    refute has_element?(view, "#{mark("name")} [data-testid='translation-chip']")

    assert text(view, "[data-testid='translation-strip-progress']") ==
             "Texts marked globe are translatable: 1 of 1 done."
  end
end
