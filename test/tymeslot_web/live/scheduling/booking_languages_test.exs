defmodule TymeslotWeb.Live.Scheduling.BookingLanguagesTest do
  @moduledoc """
  A booking page offered only in the organiser's own languages (English, the
  original, and a German translation), walked as a visitor on every
  registered theme: which language the page picks, what it refuses, what the
  switcher offers, and that a booking made in German keeps the German copies
  for the attendee beside the original wording and is rescheduled in
  German; and that the meeting's own pages (cancel, reschedule), the poll
  and the payment return pages stay in the attendee's or an offered
  language.

  The rule (`Tymeslot.ContentTranslations.Languages.visitor_locale/2`): the
  visitor's own pick (`?locale=`, or the switcher's choice the session
  remembers) wins, then the language the meeting was booked in, then the
  browser's, then the original; a pick the organiser does not offer gives
  the original. A `?locale=` not offered reloads the page with the original
  in its URL; a remembered one is left in the session, which every
  organiser's pages share.
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
  alias TymeslotWeb.ThemeTestMatrix

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

  # Organiser-specific rules, independent of the theme.

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

  test "offering every language lists every supported locale", %{conn: conn, profile: profile} do
    profile |> Changeset.change(offer_all_locales: true) |> Repo.update!()

    {:ok, view, _html} = live(conn, "/#{profile.username}")

    assert Enum.sort(switcher_locales(view)) == Enum.sort(Locales.supported_codes())
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

  test "a remembered pick one organiser does not offer is kept for another who does", %{
    conn: conn,
    profile: profile
  } do
    other = insert(:user)
    insert(:profile, user: other, username: "every-language-host", offer_all_locales: true)

    conn = conn |> init_test_session(%{chosen_locale: "fr"}) |> get("/#{profile.username}")

    assert html_response(conn, 200) =~ ~s(data-locale="en")
    assert get_session(conn, :chosen_locale) == "fr"

    {:ok, view, _html} = conn |> recycle() |> live("/every-language-host")
    assert render(view) =~ ~s(data-locale="fr")
  end

  for theme <- ThemeTestMatrix.registered() do
    describe "#{theme.name}" do
      setup %{profile: profile} do
        profile |> Changeset.change(booking_theme: unquote(theme.id)) |> Repo.update!()
        :ok
      end

      test "#{theme.slug}: the switcher lists only the offered languages", %{
        conn: conn,
        profile: profile
      } do
        {:ok, view, _html} = live(conn, "/#{profile.username}")

        assert Enum.sort(switcher_locales(view)) == ["de", "en"]
      end

      test "#{theme.slug}: the switcher is hidden when one language remains", %{
        conn: conn,
        profile: profile
      } do
        profile |> Changeset.change(translation_locales: []) |> Repo.update!()

        {:ok, view, _html} = live(conn, "/#{profile.username}")

        assert render(view) =~ ~s(data-locale="en")
        assert has_element?(view, ".theme-shell__language--hidden")
        refute has_element?(view, ".visible button[phx-click='toggle_language_dropdown']")
      end

      test "#{theme.slug}: ?locale=de shows the German meeting type name", %{
        conn: conn,
        profile: profile
      } do
        {:ok, view, _html} = live(conn, "/#{profile.username}?locale=de")

        html = render(view)
        assert html =~ ~s(data-locale="de")
        assert html =~ "Erstgespräch"
        refute html =~ "Intro call"
      end

      test "#{theme.slug}: a ?locale= patched into a running page reloads it", %{
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

      test "#{theme.slug}: a patched ?locale= not offered leaves the page as it is", %{
        conn: conn,
        profile: profile
      } do
        {:ok, view, _html} = live(conn, "/#{profile.username}")

        html = render_patch(view, "/#{profile.username}?locale=fr")
        assert html =~ ~s(data-locale="en")
        assert html =~ "Intro call"
      end

      test "#{theme.slug}: the browser's later language wins when the first is not offered",
           %{conn: conn, profile: profile} do
        {:ok, view, _html} =
          conn
          |> put_req_header("accept-language", "fr, de")
          |> live("/#{profile.username}")

        assert render(view) =~ ~s(data-locale="de")
      end

      test "#{theme.slug}: the visitor's remembered pick wins over the browser", %{
        conn: conn,
        profile: profile
      } do
        {:ok, view, _html} =
          conn
          |> init_test_session(%{chosen_locale: "de"})
          |> put_req_header("accept-language", "en")
          |> live("/#{profile.username}")

        assert render(view) =~ ~s(data-locale="de")
      end

      test "#{theme.slug}: a ?locale= not offered reloads the page in the original", %{
        conn: conn,
        profile: profile
      } do
        assert {:error, {:redirect, %{to: to}}} =
                 conn
                 |> put_req_header("accept-language", "de")
                 |> live("/#{profile.username}?locale=fr")

        assert_original(conn, to)
      end

      test "#{theme.slug}: a remembered pick not offered gives the original, not the browser's",
           %{conn: conn, profile: profile} do
        {:ok, view, _html} =
          conn
          |> init_test_session(%{chosen_locale: "fr"})
          |> put_req_header("accept-language", "de")
          |> live("/#{profile.username}")

        assert render(view) =~ ~s(data-locale="en")
      end

      for action <- ["cancel", "reschedule"] do
        test "#{theme.slug}: the #{action} page follows the attendee's language and copy", %{
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
          assert Enum.sort(switcher_locales(view)) == ["de", "en"]
        end

        test "#{theme.slug}: the visitor's pick wins over the booked language on #{action}", %{
          conn: conn,
          user: user,
          profile: profile
        } do
          meeting = german_meeting(user)

          {:ok, view, _html} =
            conn
            |> init_test_session(%{chosen_locale: "en"})
            |> put_req_header("accept-language", "de")
            |> live("/#{profile.username}/meeting/#{meeting.uid}/#{unquote(action)}")

          html = render(view)
          assert html =~ ~s(data-locale="en")
          assert html =~ "Intro call"
        end

        test "#{theme.slug}: a stale pick on #{action} gives the original, not the booked", %{
          conn: conn,
          user: user,
          profile: profile
        } do
          meeting = german_meeting(user)
          path = "/#{profile.username}/meeting/#{meeting.uid}/#{unquote(action)}"

          {:ok, view, _html} =
            conn |> init_test_session(%{chosen_locale: "fr"}) |> live(path)

          assert render(view) =~ ~s(data-locale="en")

          assert {:error, {:redirect, %{to: to}}} = live(conn, path <> "?locale=fr")
          assert_original(conn, to)
        end
      end

      test "#{theme.slug}: the poll page lists only the offered languages", %{
        conn: conn,
        user: user,
        profile: profile
      } do
        poll = insert(:poll, user: user)
        insert(:poll_time_slot, poll: poll)
        path = "/#{profile.username}/poll/#{poll.token}"

        {:ok, view, _html} =
          conn |> put_req_header("accept-language", "fr, de") |> live(path)

        assert render(view) =~ ~s(data-locale="de")
        assert Enum.sort(switcher_locales(view)) == ["de", "en"]

        {:ok, remembered, _html} =
          conn |> init_test_session(%{chosen_locale: "fr"}) |> live(path)

        assert render(remembered) =~ ~s(data-locale="en")

        assert {:error, {:redirect, %{to: to}}} = live(conn, path <> "?locale=fr")
        assert_original(conn, to)
      end

      for page <- ["payment-processing", "payment-cancelled"] do
        test "#{theme.slug}: the #{page} page follows the booked language from the first paint",
             %{conn: conn, user: user} do
          path = payment_path(user, unquote(theme.slug), unquote(page), "de")
          conn = put_req_header(conn, "accept-language", "fr-FR,fr;q=0.9")

          assert conn |> get(path) |> html_response(200) =~ ~s(data-locale="de")

          {:ok, view, _html} = live(conn, path)
          assert render(view) =~ ~s(data-locale="de")
          assert Enum.sort(switcher_locales(view)) == ["de", "en"]
        end

        test "#{theme.slug}: the #{page} page puts the visitor's pick first", %{
          conn: conn,
          user: user
        } do
          path = payment_path(user, unquote(theme.slug), unquote(page), "de")
          conn = init_test_session(conn, %{chosen_locale: "en"})

          assert conn |> get(path) |> html_response(200) =~ ~s(data-locale="en")
        end

        test "#{theme.slug}: the #{page} page shows a stale pick the original", %{
          conn: conn,
          user: user
        } do
          path = payment_path(user, unquote(theme.slug), unquote(page), "de")

          remembered = conn |> init_test_session(%{chosen_locale: "fr"}) |> get(path)
          assert html_response(remembered, 200) =~ ~s(data-locale="en")
          assert get_session(remembered, :chosen_locale) == "fr"

          to = conn |> get(with_locale(path, "fr")) |> redirected_to()
          assert URI.decode_query(URI.parse(to).query)["locale"] == "en"
          assert conn |> get(to) |> html_response(200) =~ ~s(data-locale="en")
        end
      end

      @tag :capture_log
      test "#{theme.slug}: a booking made in German keeps the attendee's copies", %{
        conn: conn,
        profile: profile
      } do
        book_in_german(conn, profile, "jana-#{unquote(theme.slug)}@example.com")

        [meeting] =
          Repo.all_by(MeetingSchema, attendee_email: "jana-#{unquote(theme.slug)}@example.com")

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

      @tag :capture_log
      test "#{theme.slug}: a German booking is rescheduled in German on an English browser", %{
        conn: conn,
        profile: profile
      } do
        email = "resched-#{unquote(theme.slug)}@example.com"
        book_in_german(conn, profile, email)
        [meeting] = Repo.all_by(MeetingSchema, attendee_email: email)

        english = put_req_header(conn, "accept-language", "en-US,en;q=0.9")

        {:ok, page, _html} =
          live(english, "/#{profile.username}/meeting/#{meeting.uid}/reschedule")

        assert render(page) =~ ~s(data-locale="de")

        assert {:error, {:live_redirect, %{to: to}}} =
                 page
                 |> element("[phx-click*='reschedule_meeting_uid']")
                 |> render_click()

        assert URI.decode_query(URI.parse(to).query)["reschedule_meeting_uid"] == meeting.uid

        {:ok, flow, _html} = live(english, to <> "&timezone=#{profile.timezone}")
        assert render(flow) =~ ~s(data-locale="de")

        BookingDriver.book(flow, answers: %{"q-company" => "Acme"}, until: :attendee)
        assert has_element?(flow, "form[data-fact='attendee']")
        assert render(flow) =~ ~s(data-locale="de")
      end
    end
  end

  # Reloaded with the original as the pick, the page is in the original.
  defp assert_original(conn, to) do
    assert URI.decode_query(URI.parse(to).query)["locale"] == "en"

    {:ok, view, _html} = live(conn, to)
    assert render(view) =~ ~s(data-locale="en")
  end

  defp with_locale(path, locale) do
    separator = if path =~ "?", do: "&", else: "?"
    path <> separator <> "locale=" <> locale
  end

  defp book_in_german(conn, profile, email) do
    {:ok, view, _html} =
      live(conn, "/#{profile.username}?locale=de&timezone=#{profile.timezone}")

    assert render(view) =~ ~s(data-locale="de")

    BookingDriver.book(view,
      answers: %{"q-company" => "Acme"},
      attendee: %{name: "Jana", email: email},
      until: :submitted
    )

    _drain = :sys.get_state(view.pid)
    view
  end

  # A meeting awaiting payment, booked in `locale`, and the return page's
  # address for it.
  defp payment_path(user, theme_slug, page, locale) do
    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: :awaiting_payment,
        attendee_locale: locale
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_LINGO"
    )

    "/themes/#{theme_slug}/#{page}/#{meeting.id}" <>
      if page == "payment-processing", do: "?session_id=cs_LINGO", else: ""
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
