defmodule TymeslotWeb.Live.Scheduling.BookingLanguageTextsTest do
  @moduledoc """
  The organiser's translated texts on a booking page offered only in English
  (the original) and German: the language switcher lands on them and the
  page remembers the pick, without the pick reaching the organiser's own
  dashboard; and a named booking page's texts, the intro and a venue's name
  are shown translated.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :i18n
  @moduletag :scheduling

  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.AuthTestHelpers
  alias Tymeslot.BookingPages
  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "lingo-texts-host",
        booking_theme: "1",
        timezone: "America/New_York",
        content_locale: "en",
        translation_locales: ["de"],
        offer_all_locales: false
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    insert(:meeting_type,
      user: user,
      name: "Intro call",
      slug: "intro-call",
      duration_minutes: 30,
      translations: %{
        "de" => %{"name" => %{"text" => "Erstgespräch", "source" => :erlang.phash2("Intro call")}}
      }
    )

    %{user: user, profile: profile}
  end

  test "an owner's pick on their own booking page is remembered there, not on the dashboard",
       %{conn: conn, user: user, profile: profile} do
    user
    |> Changeset.change(locale: nil, onboarding_completed_at: DateTime.utc_now(:second))
    |> Repo.update!()

    conn =
      conn
      |> init_test_session(%{})
      |> AuthTestHelpers.log_in_user(user)
      |> put_req_header("accept-language", "en")

    {:ok, view, _html} = live(conn, "/#{profile.username}")
    assert render(view) =~ "Intro call"

    {:ok, conn} = view |> pick_language("de") |> follow_redirect(conn)

    {:ok, picked, _html} = live(conn)
    assert render(picked) =~ "Erstgespräch"

    {:ok, again, _html} = conn |> recycle() |> live("/#{profile.username}")
    html = render(again)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Erstgespräch"

    dashboard = conn |> recycle() |> get("/dashboard/overview")
    assert html_response(dashboard, 200) =~ ~s(<html lang="en")

    {:ok, dashboard_view, _html} = conn |> recycle() |> live("/dashboard/overview")
    assert render(dashboard_view) =~ "Overview"
    refute render(dashboard_view) =~ "Übersicht"
  end

  test "the switcher on a page offering only some languages lands on the translated texts and is remembered",
       %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, "/#{profile.username}/intro-call")
    assert render(view) =~ "Intro call"

    assert Enum.sort(switcher_locales(view)) == ["de", "en"]

    assert {:error, {:redirect, %{to: to}}} =
             view
             |> element("button[phx-click='change_locale'][phx-value-locale='de']")
             |> render_click()

    assert URI.decode_query(URI.parse(to).query)["locale"] == "de"

    conn = get(conn, to)
    assert html_response(conn, 200) =~ "Erstgespräch"

    {:ok, remembered, _html} = conn |> recycle() |> live("/#{profile.username}")
    html = render(remembered)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Erstgespräch"
    refute html =~ "Intro call"
  end

  test "a named booking page shows its translated texts", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    page =
      insert(:booking_page,
        profile: profile,
        slug: "consulting",
        name: "Consulting",
        booking_text_enabled: true,
        booking_heading: "Ready to talk?",
        booking_greeting: "Hello from the consulting page"
      )

    :ok = BookingPages.set_meeting_type(page, intro_call_id(user), true)

    {:ok, _entity} =
      Catalogue.save(user.id, {:booking_page, page.id}, "de", %{
        "booking_heading" => "Bereit für ein Gespräch?",
        "booking_greeting" => "Hallo von der Beratungsseite"
      })

    {:ok, view, _html} = live(conn, "/#{profile.username}/consulting?locale=de")
    html = render(view)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Bereit für ein Gespräch?"
    assert html =~ "Hallo von der Beratungsseite"
    refute html =~ "Ready to talk?"

    {:ok, original, _html} = live(conn, "/#{profile.username}/consulting")
    assert render(original) =~ "Ready to talk?"
  end

  test "the intro is shown translated on a theme that shows it", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    profile
    |> Changeset.change(booking_theme: "4", headline: "Career coach", bio: "I help new managers.")
    |> Repo.update!()

    {:ok, _entity} =
      Catalogue.save(user.id, {:profile, profile.id}, "de", %{
        "headline" => "Karrierecoach",
        "bio" => "Ich helfe neuen Führungskräften."
      })

    {:ok, view, _html} = live(conn, "/#{profile.username}?locale=de")
    html = render(view)
    assert html =~ "Karrierecoach"
    assert html =~ "Ich helfe neuen Führungskräften."
    refute html =~ "Career coach"
    refute html =~ "I help new managers."

    {:ok, original, _html} = live(conn, "/#{profile.username}")
    assert render(original) =~ "Career coach"
  end

  @tag :capture_log
  test "a venue's translated name is shown on the booking form", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    berlin = insert(:venue, user: user, name: "Berlin office", description: "Friedrichstrasse 1")
    munich = insert(:venue, user: user, name: "Munich office", description: "Marienplatz 8")

    insert(:meeting_type,
      user: user,
      name: "Site visit",
      slug: "site-visit",
      duration_minutes: 30,
      locations: [in_person_location([berlin, munich], label: "Our offices")]
    )

    {:ok, _entity} =
      Catalogue.save(user.id, {:venue, berlin.id}, "de", %{"name" => "Büro Berlin"})

    {:ok, view, _html} =
      live(conn, "/#{profile.username}/site-visit?locale=de&timezone=#{profile.timezone}")

    BookingDriver.book(view, until: :attendee)
    assert has_element?(view, "[data-venue-id='#{berlin.id}']", "Büro Berlin")
    refute has_element?(view, "[data-venue-id='#{berlin.id}']", "Berlin office")
    # A venue left untranslated keeps its original name.
    assert has_element?(view, "[data-venue-id='#{munich.id}']", "Munich office")
  end

  defp intro_call_id(user),
    do: Repo.get_by!(MeetingTypeSchema, user_id: user.id, slug: "intro-call").id

  defp pick_language(view, locale) do
    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    view
    |> element("button[phx-click='change_locale'][phx-value-locale='#{locale}']")
    |> render_click()
  end

  defp switcher_locales(view) do
    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("button[phx-click='change_locale']", "phx-value-locale")
  end
end
