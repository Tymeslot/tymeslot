defmodule TymeslotWeb.Live.Scheduling.BookingLanguagesTest do
  @moduledoc """
  A booking page offered only in the organiser's own languages (English, the
  original, and a German translation), walked as a visitor: which language
  the page picks, what it refuses, what the switcher offers, and that a
  booking made in German keeps the German copies for the attendee beside the
  original wording.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :i18n
  @moduletag :scheduling

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
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
        username: "lingo-host",
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
      duration_minutes: 30,
      custom_fields: [
        %FieldDefinition{id: "q-company", type: "short_text", label: "Company", position: 0}
      ],
      translations: %{
        "de" => %{
          "name" => %{"text" => "Erstgespräch", "source" => :erlang.phash2("Intro call")},
          "custom_fields/q-company/label" => %{
            "text" => "Firma",
            "source" => :erlang.phash2("Company")
          }
        }
      }
    )

    %{profile: profile}
  end

  test "a visitor asking for French gets the original language", %{conn: conn, profile: profile} do
    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "fr-FR,fr;q=0.9")
      |> live("/#{profile.username}")

    html = render(view)
    assert html =~ ~s(data-locale="en")
    assert html =~ "Intro call"
    refute html =~ "Erstgespräch"
  end

  test "?locale=de shows the German meeting type name and question label", %{
    conn: conn,
    profile: profile
  } do
    {:ok, view, _html} = live(conn, "/#{profile.username}?locale=de")
    html = render(view)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Erstgespräch"
    refute html =~ "Intro call"

    view = navigate_to_booking_form(conn, profile, nil, locale: "de")
    assert has_element?(view, "[data-fact='answer'][data-question='q-company']")
    assert render(view) =~ "Firma"
    refute render(view) =~ "Company"
  end

  test "?locale=fr is refused", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, "/#{profile.username}?locale=fr")

    html = render(view)
    assert html =~ ~s(data-locale="en")
    assert html =~ "Intro call"
  end

  test "the switcher lists only the offered languages", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    offered =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("button[phx-click='change_locale']", "phx-value-locale")

    assert Enum.sort(offered) == ["de", "en"]
  end

  @tag :capture_log
  test "a booking made in German keeps the attendee's copies beside the original", %{
    conn: conn,
    profile: profile
  } do
    view = navigate_to_booking_form(conn, profile, nil, locale: "de")
    BookingDriver.answer(view, "q-company", "Acme")
    BookingDriver.continue(view)
    BookingDriver.submit(view, %{name: "Jana", email: "jana@example.com"})
    _drain = :sys.get_state(view.pid)

    [meeting] = Repo.all_by(MeetingSchema, attendee_email: "jana@example.com")

    assert meeting.attendee_locale == "de"
    assert meeting.meeting_type == "Intro call"
    assert [%{"label" => "Company"}] = meeting.custom_fields_snapshot

    assert %{
             "locale" => "de",
             "meeting_type" => "Erstgespräch",
             "custom_fields_snapshot" => [%{"label" => "Firma"}]
           } = meeting.attendee_texts
  end
end
