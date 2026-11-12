defmodule TymeslotWeb.Live.Scheduling.BookingLanguagesTest do
  @moduledoc """
  A booking page offered only in the organiser's own languages (English, the
  original, and a German translation), walked as a visitor: which language
  the page picks, what it refuses, what the switcher offers, and that a
  booking made in German keeps the German copies for the attendee beside the
  original wording; and that the meeting's own pages (cancel, reschedule,
  cancel confirmed) and the payment return page stay in the attendee's or
  an offered language.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :i18n
  @moduletag :scheduling

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Locales
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

    %{user: user, profile: profile}
  end

  # German is the original here, so a page falling back to the instance
  # default (English) instead of the organiser's original would fail.
  test "a visitor asking for French gets the original language", %{conn: conn, profile: profile} do
    profile
    |> Changeset.change(content_locale: "de", translation_locales: ["en"])
    |> Repo.update!()

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "fr-FR,fr;q=0.9")
      |> live("/#{profile.username}")

    html = render(view)
    assert html =~ ~s(data-locale="de")
    refute html =~ ~s(data-locale="en")
  end

  test "a visitor's later Accept-Language choice wins when the first is not offered", %{
    conn: conn,
    profile: profile
  } do
    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "fr, de")
      |> live("/#{profile.username}")

    html = render(view)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Erstgespräch"
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

  test "a ?locale= patched into a running page reloads it in that language", %{
    conn: conn,
    profile: profile
  } do
    {:ok, view, _html} = live(conn, "/#{profile.username}")
    assert render(view) =~ "Intro call"

    path = "/#{profile.username}?locale=de"
    assert {:error, {:redirect, %{to: to}}} = render_patch(view, path)
    assert to =~ path

    {:ok, reloaded, _html} = live(conn, to)
    html = render(reloaded)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Erstgespräch"
  end

  test "a patched ?locale= the organiser does not offer leaves the page as it is", %{
    conn: conn,
    profile: profile
  } do
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    html = render_patch(view, "/#{profile.username}?locale=fr")
    assert html =~ ~s(data-locale="en")
    assert html =~ "Intro call"
  end

  test "the switcher lists only the offered languages", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    assert Enum.sort(switcher_locales(view)) == ["de", "en"]
  end

  test "the switcher is hidden when the organiser offers one language", %{
    conn: conn,
    profile: profile
  } do
    profile |> Changeset.change(translation_locales: []) |> Repo.update!()

    {:ok, view, _html} = live(conn, "/#{profile.username}")

    assert render(view) =~ ~s(data-locale="en")
    assert has_element?(view, ".theme-shell__language--hidden")
    refute has_element?(view, ".visible button[phx-click='toggle_language_dropdown']")
  end

  test "offering every language lists every supported locale", %{conn: conn, profile: profile} do
    profile |> Changeset.change(offer_all_locales: true) |> Repo.update!()

    {:ok, view, _html} = live(conn, "/#{profile.username}")

    assert Enum.sort(switcher_locales(view)) == Enum.sort(Locales.supported_codes())
  end

  describe "a meeting's own pages" do
    test "the cancel page's switcher lists only the offered languages", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      meeting = insert(:meeting, organizer_user_id: user.id, organizer_user: user)

      {:ok, view, _html} = live(conn, "/#{profile.username}/meeting/#{meeting.uid}/cancel")

      assert Enum.sort(switcher_locales(view)) == ["de", "en"]
    end

    for action <- ["cancel", "reschedule"] do
      test "the #{action} page follows the attendee's language and copy", %{
        conn: conn,
        user: user,
        profile: profile
      } do
        meeting = german_meeting(user)

        {:ok, view, _html} =
          conn
          |> put_req_header("accept-language", "en-US,en;q=0.9")
          |> live("/#{profile.username}/meeting/#{meeting.uid}/#{unquote(action)}")

        html = render(view)
        assert html =~ ~s(data-locale="de")
        assert html =~ "Erstgespräch"
        refute html =~ "Intro call"
      end
    end

    test "?locale= still chooses another offered language on the cancel page", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      meeting = german_meeting(user)

      {:ok, view, _html} =
        live(conn, "/#{profile.username}/meeting/#{meeting.uid}/cancel?locale=en")

      html = render(view)
      assert html =~ ~s(data-locale="en")
      assert html =~ "Intro call"
    end

    test "a meeting booked before attendee copies shows its original meeting type", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_user: user,
          meeting_type: "Intro call",
          attendee_locale: "de",
          attendee_texts: nil
        )

      {:ok, view, _html} = live(conn, "/#{profile.username}/meeting/#{meeting.uid}/cancel")

      html = render(view)
      assert html =~ ~s(data-locale="de")
      assert html =~ "Intro call"
    end
  end

  test "the payment return page stays in a language the organiser offers", %{
    conn: conn,
    user: user
  } do
    meeting = insert(:meeting, organizer_user_id: user.id, status: :awaiting_payment)

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_LINGO"
    )

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "fr-FR,fr;q=0.9")
      |> live("/themes/quill/payment-processing/#{meeting.id}?session_id=cs_LINGO")

    assert render(view) =~ ~s(data-locale="en")
    assert Enum.sort(switcher_locales(view)) == ["de", "en"]
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
             "de" => %{
               "meeting_type" => "Erstgespräch",
               "custom_fields_snapshot" => [%{"label" => "Firma"}]
             }
           } = meeting.attendee_texts

    assert Map.keys(meeting.attendee_texts) == ["de"]
  end

  defp german_meeting(user) do
    insert(:meeting,
      organizer_user_id: user.id,
      organizer_user: user,
      meeting_type: "Intro call",
      attendee_locale: "de",
      attendee_texts: %{"de" => %{"meeting_type" => "Erstgespräch"}}
    )
  end

  defp switcher_locales(view) do
    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("button[phx-click='change_locale']", "phx-value-locale")
  end
end
