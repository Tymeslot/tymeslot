defmodule TymeslotWeb.Live.Themes.PaperThemeTest do
  @moduledoc """
  Paper's booking page through the real routes: the overview's list of
  meeting types with their lengths, locations and a paid type's price,
  choosing one and going on with Next, the logo in the avatar's place, the
  schedule screen's details beside the month calendar and, once a time is
  picked, the questions and the details form below it with one submit, Back
  to the meeting types, the address following the facts, the style block
  each colour mode writes, and the meeting pages in Paper's card. The
  shared flow suites book through it as through every theme in
  `ThemeTestMatrix`.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.BookingDriver.Page
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @theme_id "3"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    seed_booking_account(@theme_id, "paper-organiser", "Etc/UTC")
  end

  defp customise(profile, settings),
    do: insert(:theme_customization, profile: profile, theme_id: @theme_id, settings: settings)

  test "the overview lists the meeting types in Paper's card", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, ".paper-theme-wrapper [data-testid='paper-overview'].booker-card")

    assert has_element?(
             view,
             "button.paper-type[data-duration='quick-chat']"
           )

    assert has_element?(view, "button.paper-type .paper-type__duration", "30 minutes")
    refute has_element?(view, "[data-testid='paper-overview'] [data-testid='next-step']")

    # Choosing the type is the way on: no Next between.
    view |> element("button[data-duration='quick-chat']") |> render_click()

    assert has_element?(
             view,
             "#schedule-step[data-testid='paper-schedule'] .paper-details h1",
             "Quick Chat"
           )

    refute has_element?(view, "[data-testid='paper-overview']")
    refute has_element?(view, "[data-testid='next-step']")

    # Back on the overview, the row the visitor chose stays marked.
    view |> element("[data-intent='back']") |> render_click()

    assert has_element?(view, "button[data-duration='quick-chat'][aria-current='true']")
  end

  test "each meeting type on the overview names where it is held",
       %{conn: conn, user: user, profile: profile} do
    insert(:meeting_type,
      user: user,
      name: "Site Visit",
      duration_minutes: 45,
      locations: [
        %LocationOption{id: "office", kind: "in_person", label: "Our studio", position: 0}
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(
             view,
             "button.paper-type[data-duration='site-visit'] [data-testid='paper-type-location']",
             "Our studio"
           )

    refute has_element?(
             view,
             "button.paper-type[data-duration='quick-chat'] [data-testid='paper-type-location']",
             "Our studio"
           )
  end

  test "a paid meeting type shows its price in the organiser's currency",
       %{conn: conn, user: user, profile: profile} do
    insert(:connect_account, user: user, default_currency: "chf")

    insert(:meeting_type,
      user: user,
      name: "Strategy Session",
      duration_minutes: 60,
      payment_required: true,
      price_cents: 12_000
    )

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, "button.paper-type .paper-type__price", "CHF 120.00")
  end

  test "an uploaded logo takes the avatar's place", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
    assert has_element?(view, ".paper-intro img.paper-avatar")
    refute has_element?(view, ".paper-brand")

    logo = "themes/#{profile.id}/3/images/logo.png"
    customise(profile, %{"color_scheme" => "neutral", "logo_path" => logo})

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
    assert has_element?(view, ".paper-brand img.paper-logo[src='/uploads/#{logo}']")
    refute has_element?(view, ".paper-intro img.paper-avatar")
  end

  test "the schedule screen puts the meeting's details beside the month calendar",
       %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat")

    assert has_element?(view, "[data-testid='paper-schedule'] .paper-details h1", "Quick Chat")
    assert has_element?(view, ".paper-details .paper-fact", "30 minutes")

    assert has_element?(
             view,
             ".paper-calendar button.calendar-nav-button[phx-click='next_month'][aria-label='Next month']"
           )

    # A type's own link: no Next, and no actions bar (no Back to show).
    refute has_element?(view, "[data-testid='next-step']")
    refute has_element?(view, "[data-testid='schedule-actions']")
  end

  describe "the second screen" do
    test "opens the details below the picker once a time is picked", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=Etc/UTC")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.continue(view)

      refute has_element?(view, "[data-testid='paper-book']")

      BookingDriver.pick_first_slot(view,
        on: Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
      )

      assert has_element?(view, "#schedule-step[data-testid='paper-schedule']")

      assert has_element?(
               view,
               "#schedule-step [data-testid='paper-book'] form[data-fact='attendee']"
             )

      assert has_element?(
               view,
               "[data-testid='paper-book'] [data-testid='submit-booking'][data-intent='submit']"
             )

      assert has_element?(view, "[data-testid='paper-book-when']")

      # The part shares the schedule's grid with the details column and the
      # picker, so a wide card can swap it in place of the picker.
      assert has_element?(
               view,
               "[data-testid='paper-schedule'] .paper-schedule > [data-testid='paper-book']"
             )

      assert has_element?(
               view,
               "[data-testid='paper-change-time'][phx-click*='remove_class'][phx-click*='paper-card--booking']"
             )

      assert has_element?(
               view,
               "[id^='paper-book-head-'][phx-mounted*='add_class'][phx-mounted*='paper-card--booking']"
             )

      assert has_element?(
               view,
               "[data-testid='paper-book-when'] button[type='button'][data-testid='paper-change-time']",
               "Change time"
             )

      # The button hands the focus to the chosen time, so that element has
      # to exist once the time is picked.
      selector = Page.focus_target(view, "[data-testid='paper-change-time']")
      assert selector =~ "selected"
      assert has_element?(view, selector)

      assert has_element?(
               view,
               "[data-testid='paper-book'] .paper-book__title",
               "Enter your details"
             )

      assert has_element?(view, "[data-testid='paper-book'] label", "Message (optional)")

      refute has_element?(
               view,
               "[data-testid='paper-book'] label",
               "Additional Message (Optional)"
             )

      refute has_element?(view, "[data-testid='paper-book'] label", "Your Name")
    end

    test "shows every question above the form once a time is picked, with no way on", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      ask_questions(user)

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=Etc/UTC")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.continue(view)

      refute has_element?(view, "[data-fact='answer']")

      BookingDriver.pick_first_slot(view,
        on: Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
      )

      assert has_element?(
               view,
               "[data-testid='paper-book'] [data-fact='answer'][data-question='p-company']"
             )

      assert has_element?(
               view,
               "[data-testid='paper-book'] [data-fact='answer'][data-question='p-team']"
             )

      assert has_element?(view, "[data-testid='paper-book'] form[data-fact='attendee']")
      refute has_element?(view, "[data-testid='paper-book'] [data-intent='continue']")

      # Only the required question carries the marker, and its input says so.
      assert has_element?(
               view,
               "[data-testid='paper-question'][data-index='0'] .paper-question__label [data-testid='paper-question-required']",
               "*"
             )

      assert has_element?(
               view,
               "[data-testid='paper-question'][data-index='0'] input[aria-required='true']"
             )

      refute has_element?(
               view,
               "[data-testid='paper-question'][data-index='1'] [data-testid='paper-question-required']"
             )
    end

    @tag :capture_log
    test "books the answers given above the form with the one submit", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      ask_questions(user)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=Etc/UTC")

      BookingDriver.book(view,
        answers: %{"p-team" => "Design", "p-company" => "Acme"},
        attendee: %{name: "Ana Silva", email: "ana-paper@example.com"}
      )

      meeting = Repo.get_by!(MeetingSchema, attendee_email: "ana-paper@example.com")
      assert meeting.custom_field_answers == %{"p-company" => "Acme", "p-team" => "Design"}
      assert Enum.map(meeting.custom_fields_snapshot, & &1["id"]) == ["p-company", "p-team"]
    end

    @tag :capture_log
    test "a submit with a required question unanswered names it and books nothing", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      ask_questions(user)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=Etc/UTC")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.continue(view)

      BookingDriver.pick_first_slot(view,
        on: Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
      )

      BookingDriver.submit(view, %{name: "Ana Silva", email: "ana-blank@example.com"})

      assert has_element?(
               view,
               "[data-testid='paper-question'][data-index='0'] .paper-question__error"
             )

      refute has_element?(
               view,
               "[data-testid='paper-question'][data-index='1'] .paper-question__error"
             )

      assert has_element?(view, "[data-testid='paper-book'] form[data-fact='attendee']")
      refute Repo.get_by(MeetingSchema, attendee_email: "ana-blank@example.com")

      BookingDriver.answer(view, "p-company", "Acme")

      refute has_element?(view, ".paper-question__error")
    end

    @tag :capture_log
    test "changing the time after filling the form books the new time and keeps the answers", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      ask_questions(user)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=Etc/UTC")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.continue(view)

      day = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
      {^day, first} = BookingDriver.pick_first_slot(view, on: day)

      BookingDriver.answer(view, "p-company", "Acme")
      BookingDriver.answer(view, "p-team", "Design")
      BookingDriver.fill_attendee(view, %{name: "Ana Silva", email: "ana-change@example.com"})

      second =
        view
        |> Page.attribute("[data-fact='time']", "data-value")
        |> Enum.find(&(&1 != first))

      assert second =~ ":"
      BookingDriver.pick_time(view, second)

      assert Page.attribute(view, "[data-fact='time'][aria-pressed='true']", "data-value") ==
               [second]

      BookingDriver.submit(view)

      meeting = Repo.get_by!(MeetingSchema, attendee_email: "ana-change@example.com")
      assert meeting.attendee_name == "Ana Silva"
      assert meeting.custom_field_answers == %{"p-company" => "Acme", "p-team" => "Design"}

      assert DateTime.to_date(meeting.start_time) == Date.from_iso8601!(day)
      assert Calendar.strftime(meeting.start_time, "%-I:%M %p") == second
      refute Calendar.strftime(meeting.start_time, "%-I:%M %p") == first
    end

    test "Back returns to the meeting types", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.continue(view)

      BookingDriver.back(view)

      assert has_element?(view, "[data-testid='paper-overview']")
    end

    test "Back goes straight to the meeting types from a screen with questions answered", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      ask_questions(user)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=Etc/UTC")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.continue(view)

      BookingDriver.pick_first_slot(view,
        on: Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
      )

      view
      |> form("form[data-fact='answer'][data-question='p-company']", %{"value" => "Acme"})
      |> render_submit()

      BookingDriver.answer(view, "p-team", "Design")
      BookingDriver.back(view)

      assert has_element?(view, "[data-testid='paper-overview']")
    end

    test "the address follows the type and the time", %{conn: conn, profile: profile} do
      user = profile.username
      {:ok, view, _html} = live(conn, "/#{user}")

      BookingDriver.choose_meeting_type(view, "quick-chat")
      assert_patch(view, "/#{user}/quick-chat")

      BookingDriver.continue(view)

      BookingDriver.pick_first_slot(view,
        on: Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
      )

      assert_patch(view, "/#{user}/quick-chat/book")
    end

    @tag :capture_log
    test "the address follows the booking to the thank-you page", %{
      conn: conn,
      profile: profile
    } do
      user = profile.username
      {:ok, view, _html} = live(conn, "/#{user}")

      BookingDriver.book(view)

      assert_patch(view, "/#{user}/thank-you")
      assert has_element?(view, "[data-testid='confirmation-heading']")
    end

    test "a link to /book with no day and time opens the schedule screen, with no form", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat/book")

      assert has_element?(view, "#schedule-step [data-fact='date']")
      refute has_element?(view, "form[data-fact='attendee']")
    end

    test "a meeting type's own link opens on it, with no way back", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat")

      assert has_element?(view, "[data-testid='paper-schedule'] [data-fact='date']")
      refute has_element?(view, "[data-intent='back']")
    end

    @tag :capture_log
    test "a required note must be acknowledged, and the confirmation lists the answers", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      ask(user, [
        %{
          "id" => "p-terms",
          "type" => "note",
          "label" => "Terms",
          "body" => "Please agree to the call recording terms.",
          "required" => true,
          "position" => 0
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=Etc/UTC")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.continue(view)

      BookingDriver.pick_first_slot(view,
        on: Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
      )

      assert has_element?(
               view,
               "[data-testid='paper-question']",
               "Please agree to the call recording terms."
             )

      BookingDriver.submit(view, %{name: "Ana Silva", email: "ana-note@example.com"})

      assert has_element?(
               view,
               "[data-testid='paper-question'][data-index='0'] .paper-question__error"
             )

      refute Repo.get_by(MeetingSchema, attendee_email: "ana-note@example.com")

      BookingDriver.answer(view, "p-terms", "acknowledge")
      BookingDriver.submit(view, %{name: "Ana Silva", email: "ana-note@example.com"})
      wait_until(fn -> has_element?(view, "[data-testid='confirmation-heading']") end)

      assert has_element?(view, ".custom-answers", "Terms")

      meeting = Repo.get_by!(MeetingSchema, attendee_email: "ana-note@example.com")
      assert %{"confirmed" => true} = meeting.custom_field_answers["p-terms"]
    end

    @tag :capture_log
    test "the questions are asked again, blank, after Schedule another", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      ask_questions(user)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=Etc/UTC")

      BookingDriver.book(view,
        answers: %{"p-company" => "Acme Corp"},
        attendee: %{name: "Ana Silva", email: "ana-again@example.com"}
      )

      assert render(view) =~ "Acme Corp"

      BookingDriver.restart(view)
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.continue(view)

      BookingDriver.pick_first_slot(view,
        on: Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
      )

      assert has_element?(view, "form[data-fact='answer'][data-question='p-company']")
      refute render(view) =~ "Acme Corp"
    end

    test "a thank-you address with no booking behind it opens the meeting types", %{
      conn: conn,
      profile: profile
    } do
      user = profile.username

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/#{user}/thank-you?timezone=Etc%2FUTC")

      assert to == "/#{user}?timezone=Etc%2FUTC"
    end
  end

  test "the colour mode decides the page's style block", %{conn: conn, profile: profile} do
    {:ok, _view, auto} = live(conn, ~p"/#{profile.username}")

    assert auto =~ "--theme-color-scheme: light dark;"
    assert auto =~ "@media (prefers-color-scheme: dark)"

    customise(profile, %{"color_scheme" => "cool", "colour_mode" => "dark"})

    {:ok, _view, dark} = live(conn, ~p"/#{profile.username}")

    assert dark =~ "--theme-color-scheme: dark;"
    assert dark =~ "--theme-canvas: #0b1120;"
    refute dark =~ "prefers-color-scheme"
  end

  test "the page loads Paper's stylesheet and classes", %{conn: conn, profile: profile} do
    html = conn |> get(~p"/#{profile.username}") |> html_response(200)

    assert html =~ "/assets/scheduling-theme-paper.css"
    assert html =~ ~s(class="scheduling-app theme-3 paper-theme")
  end

  test "the overview speaks in Paper's neutral voice", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, ".paper-title", "Book a meeting with")
    assert has_element?(view, ".paper-intro__instruction", "Select a meeting type")
    refute has_element?(view, ".paper-intro__greeting")
  end

  test "the organiser's own booking text replaces Paper's voice",
       %{conn: conn, profile: profile} do
    profile
    |> Changeset.change(%{
      booking_text_enabled: true,
      booking_heading: "Ready to grow your business?",
      booking_greeting: "I am Ana.",
      booking_instruction: "Choose a session."
    })
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, ".paper-title", "Ready to grow your business?")
    assert has_element?(view, ".paper-intro__greeting", "I am Ana.")
  end

  test "the organiser's blank greeting and instruction leave no paragraph behind",
       %{conn: conn, profile: profile} do
    profile
    |> Changeset.change(%{
      booking_text_enabled: true,
      booking_heading: "Ready to grow your business?",
      booking_greeting: nil,
      booking_instruction: nil
    })
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, ".paper-title", "Ready to grow your business?")
    refute has_element?(view, ".paper-intro__greeting")
    # Blank means unsaid: Paper's own instruction does not stand in for it.
    refute has_element?(view, ".paper-intro__instruction")
  end

  test "the dashboard's and the onboarding wizard's pickers offer Paper" do
    assert {"Paper", "3"} in ThemeInfo.theme_options()
  end

  # Two questions on the organiser's meeting type: a required one first,
  # then an optional one.
  defp ask_questions(user) do
    ask(user, [
      %{
        "id" => "p-company",
        "type" => "short_text",
        "label" => "Company",
        "required" => true,
        "position" => 0
      },
      %{
        "id" => "p-team",
        "type" => "short_text",
        "label" => "Team",
        "required" => false,
        "position" => 1
      }
    ])
  end

  # The organiser's meeting type asks `questions`.
  defp ask(user, questions) do
    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)

    {:ok, _meeting_type} =
      MeetingTypes.update_meeting_type(meeting_type, %{"custom_fields" => questions})
  end
end
