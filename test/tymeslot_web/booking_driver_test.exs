defmodule TymeslotWeb.BookingDriverTest do
  @moduledoc """
  `TymeslotWeb.BookingDriver` on every registered theme. The shared flow
  suites trust it to book, to pick exactly the time asked for, to find a
  first free time a week out, to answer questions and to move back and
  start again on any theme, so each is pinned here per theme, with the
  database as the witness where a booking is made.

  `book/2`, `pick_slot/3` and `pick_first_slot/2` run on every registered
  theme, whatever its journey. The step-by-step tests (a way on taken right
  after the meeting-type choice, the way back, a fresh start showing the
  choices again) presuppose one page per step, so they run on the classic
  journey only. How `continue/1` and `choose_meeting_type/2` behave on a
  page that moves on by itself, or defaults its meeting type, is pinned on
  their decision functions, page by page.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :scheduling
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  @timezone "Etc/UTC"

  # One page per step: the step-level tests run on the classic journey only
  # (Reconciliation 24).
  @stepwise Enum.filter(ThemeTestMatrix.registered(), &(&1.journey == :classic))

  # Pickers that show a bounded run of days with no way to a later one:
  # Fixture Talk's `DayChips` (JC6, no period arrows). On these the pick
  # tests ask for a day the picker shows. `NextSlots` always offers the next
  # week, so Fixture Express is not among them.
  @bounded ["95"]

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  for theme <- ThemeTestMatrix.registered() do
    describe "#{theme.name}" do
      @describetag theme_id: theme.id
      @describetag slug: theme.slug
      @describetag journey: theme.journey

      @tag :capture_log
      test "book/2 books the first free time and returns the outcome",
           %{conn: conn, theme_id: theme_id, slug: slug} do
        %{user: user, profile: profile} =
          seed_booking_account(theme_id, "drive-book-#{slug}", @timezone)

        html =
          conn
          |> open(profile)
          |> BookingDriver.book(
            attendee: %{
              name: "Ada Lovelace",
              email: "ada-#{slug}@example.com",
              message: "Hello there"
            }
          )

        assert html =~ ~s(data-intent="restart")

        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
        assert meeting.attendee_email == "ada-#{slug}@example.com"
        assert meeting.status == "confirmed"
      end

      @tag :capture_log
      test "book/2 answers the questions it is given, of every kind",
           %{conn: conn, theme_id: theme_id, slug: slug} do
        %{user: user, profile: profile} =
          seed_booking_account(theme_id, "drive-answers-#{slug}", @timezone)

        ask_questions(user)

        conn
        |> open(profile)
        |> BookingDriver.book(
          answers: %{
            "dq-company" => "Acme Corp",
            "dq-recorded" => true,
            "dq-topics" => ["design", "pricing"]
          },
          attendee: %{name: "Ada Lovelace", email: "answers-#{slug}@example.com"}
        )

        answers = Repo.get_by!(MeetingSchema, organizer_user_id: user.id).custom_field_answers

        assert answers["dq-company"] == "Acme Corp"
        assert answers["dq-recorded"] == true
        assert Enum.sort(answers["dq-topics"]) == ["design", "pricing"]
      end

      @tag :capture_log
      test "book/2 until: :attendee stops at the form and books nothing",
           %{conn: conn, theme_id: theme_id, slug: slug} do
        %{user: user, profile: profile} =
          seed_booking_account(theme_id, "drive-stop-#{slug}", @timezone)

        view = open(conn, profile)
        html = BookingDriver.book(view, until: :attendee)

        assert html =~ ~s(data-fact="attendee")
        assert Repo.get_by(MeetingSchema, organizer_user_id: user.id) == nil
      end

      @tag :capture_log
      test "fill_attendee/2 writes into the form that submit/2 then sends",
           %{conn: conn, theme_id: theme_id, slug: slug} do
        %{user: user, profile: profile} =
          seed_booking_account(theme_id, "drive-fill-#{slug}", @timezone)

        view = open(conn, profile)
        BookingDriver.book(view, until: :attendee)

        BookingDriver.fill_attendee(view, %{
          name: "Grace Hopper",
          email: "fill-#{slug}@example.com"
        })

        assert has_element?(
                 view,
                 "form[data-fact='attendee'] input[name='booking[email]'][value='fill-#{slug}@example.com']"
               )

        BookingDriver.submit(view)

        wait_until(fn -> Repo.get_by(MeetingSchema, organizer_user_id: user.id) end)

        assert Repo.get_by!(MeetingSchema, organizer_user_id: user.id).attendee_name ==
                 "Grace Hopper"
      end

      @tag :capture_log
      test "pick_slot/3 books exactly the day and time asked for, bringing the day into view",
           %{conn: conn, theme_id: theme_id, slug: slug, journey: journey} do
        %{user: user, profile: profile} =
          seed_booking_account(theme_id, "drive-slot-#{slug}", @timezone)

        widen_window(profile)
        view = open(conn, profile)
        to_picker(view, journey)

        {iso, time} =
          if theme_id in @bounded do
            BookingDriver.pick_first_slot(view)
          else
            day = Date.to_iso8601(past_first_period(9))

            # The picker must have to move to reach it, or the way there
            # goes untested.
            refute day in days_on_show(view), "#{day} is already on show"

            BookingDriver.pick_slot(view, day, "10:00 AM")
            {day, "10:00 AM"}
          end

        BookingDriver.continue(view)
        BookingDriver.submit(view, %{name: "Ada Lovelace", email: "slot-#{slug}@example.com"})

        wait_until(fn -> Repo.get_by(MeetingSchema, organizer_user_id: user.id) end)
        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)

        assert DateTime.compare(meeting.start_time, at(iso, time)) == :eq
      end

      @tag :capture_log
      test "pick_first_slot/2 finds the first free time more than a week out",
           %{conn: conn, theme_id: theme_id, slug: slug, journey: journey} do
        %{profile: profile} = seed_booking_account(theme_id, "drive-later-#{slug}", @timezone)
        earliest = past_first_period(8)

        widen_window(profile,
          min_advance_hours: Date.diff(earliest, Date.utc_today()) * 24
        )

        # The page lands the booker on the week and month of the first free
        # day (`calendar_landing`), here in a later month than today's, so the
        # pick reads a period the page moved to by itself; the way on by
        # `later` is pinned by the `pick_slot/3` test.
        view = open(conn, profile)
        to_picker(view, journey)

        {iso, time} = BookingDriver.pick_first_slot(view)

        assert Date.diff(Date.from_iso8601!(iso), Date.utc_today()) >= 8
        assert Date.compare(Date.from_iso8601!(iso), earliest) != :lt
        assert %{selected_date: ^iso, selected_time: ^time} = live_assigns(view)
        refute has_element?(view, "[data-intent='continue'][disabled]")
      end

      @tag :capture_log
      test "pick_first_slot/2 with on: picks that day's first free time",
           %{conn: conn, theme_id: theme_id, slug: slug, journey: journey} do
        %{profile: profile} = seed_booking_account(theme_id, "drive-on-#{slug}", @timezone)
        today = Date.to_iso8601(Date.utc_today())
        view = open(conn, profile)
        to_picker(view, journey)

        day =
          if theme_id in @bounded,
            do: last_day_on_show(view),
            else: Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

        assert {^day, time} = BookingDriver.pick_first_slot(view, on: day)
        assert %{selected_date: ^day, selected_time: ^time} = live_assigns(view)

        # Every day after today starts its free times at 09:00 (the seed).
        if day != today, do: assert(time == "9:00 AM")
      end
    end
  end

  for theme <- @stepwise do
    describe "#{theme.name}, step by step" do
      @describetag theme_id: theme.id
      @describetag slug: theme.slug

      test "continue/1 after the choice leaves the meeting types, back/1 returns to them",
           %{conn: conn, theme_id: theme_id, slug: slug} do
        %{profile: profile} = seed_booking_account(theme_id, "drive-back-#{slug}", @timezone)
        view = open(conn, profile)

        BookingDriver.choose_meeting_type(view, "quick-chat")
        BookingDriver.continue(view)
        refute has_element?(view, "[data-fact='meeting_type']")

        BookingDriver.back(view)

        assert BookingDriver.meeting_types(view) == ["quick-chat"]
      end

      @tag :capture_log
      test "restart/1 starts a fresh booking at the meeting types",
           %{conn: conn, theme_id: theme_id, slug: slug} do
        %{profile: profile} = seed_booking_account(theme_id, "drive-again-#{slug}", @timezone)
        view = open(conn, profile)

        BookingDriver.book(view,
          attendee: %{name: "Ada Lovelace", email: "again-#{slug}@example.com"}
        )

        BookingDriver.restart(view)

        assert BookingDriver.meeting_types(view) == ["quick-chat"]
      end

      test "choose_meeting_type/2 names the types offered when asked for another",
           %{conn: conn, theme_id: theme_id, slug: slug} do
        %{profile: profile} = seed_booking_account(theme_id, "drive-other-#{slug}", @timezone)
        view = open(conn, profile)

        assert_raise ExUnit.AssertionError, ~r/"long-talk" \(offered: \["quick-chat"\]\)/, fn ->
          BookingDriver.choose_meeting_type(view, "long-talk")
        end
      end

      test "book/2 checks the meeting type asked for where the page renders no choice",
           %{conn: conn, theme_id: theme_id, slug: slug} do
        %{profile: profile} = seed_booking_account(theme_id, "drive-held-#{slug}", @timezone)

        # The meeting type's own link opens on its slot picker, with no choice.
        assert_raise ExUnit.AssertionError, ~r/holds "quick-chat", not "long-talk"/, fn ->
          conn
          |> open(profile, "quick-chat")
          |> BookingDriver.book(meeting_type: "long-talk", until: :attendee)
        end

        html =
          conn
          |> open(profile, "quick-chat")
          |> BookingDriver.book(meeting_type: "quick-chat", until: :attendee)

        assert html =~ ~s(data-fact="attendee")
      end

      test "pick_first_slot/2 names the facts a page without a picker lacks",
           %{conn: conn, theme_id: theme_id, slug: slug} do
        %{profile: profile} = seed_booking_account(theme_id, "drive-none-#{slug}", @timezone)
        view = open(conn, profile)

        assert_raise ExUnit.AssertionError,
                     ~r/marks no day \(data-fact=date\) and no slot \(data-fact=slot\)/,
                     fn -> BookingDriver.pick_first_slot(view) end
      end
    end
  end

  describe "continue/1 on a page that moves on by itself" do
    test "takes a way on whenever the page renders one, before it is enabled too" do
      html = page([offer: "current"], ~s(<button data-intent="continue" disabled>Next</button>))

      assert BookingDriver.continue_move(html, "offer") == :click
    end

    test "accepts a page that opened the next moment after the last action" do
      assert BookingDriver.continue_move(page(offer: "done", ask: "current"), "offer") == :opened
    end

    test "takes no way on of a moment that opened by itself after the last action" do
      html =
        page(
          [offer: "done", ask: "current"],
          ~s(<button data-intent="continue">Continue</button>)
        )

      assert BookingDriver.continue_move(html, "offer") == :opened
    end

    test "refuses a page still on the moment the last action was made in" do
      assert {:stuck, _reason} =
               BookingDriver.continue_move(page(offer: "done", ask: "current"), "ask")
    end

    test "with no action yet, accepts a done moment before the current one" do
      html = page(intro: "open", offer: "done", ask: "current")

      assert BookingDriver.continue_move(html, nil) == :opened
    end

    test "with no action yet, refuses a page that has moved on from nothing" do
      assert {:stuck, _reason} =
               BookingDriver.continue_move(page(intro: "open", offer: "current"), nil)
    end

    test "refuses a page with neither a way on nor marked moments" do
      assert {:stuck, _reason} = BookingDriver.continue_move("<main></main>", nil)
    end
  end

  describe "choose_meeting_type/2 on a page that defaults the meeting type" do
    test "clicks while the page renders a choice, whatever is chosen" do
      html =
        ~s(<main><button data-fact="meeting_type" data-value="quick-chat">Quick Chat</button></main>)

      assert BookingDriver.choice_move(html, "quick-chat", "quick-chat") == :click
      assert BookingDriver.choice_move(html, nil, "quick-chat") == :click
    end

    test "does nothing when no choice is rendered and the type is already chosen" do
      html = page(offer: "done", ask: "current")

      assert BookingDriver.choice_move(html, "quick-chat", "quick-chat") == :chosen
    end

    test "refuses when no choice is rendered and another type, or none, is chosen" do
      html = page(ask: "current")

      assert {:stuck, _reason} = BookingDriver.choice_move(html, "long-talk", "quick-chat")
      assert {:stuck, _reason} = BookingDriver.choice_move(html, nil, "quick-chat")
    end
  end

  # A page of journey moments as `Continuous` and `Transcript` mark them
  # (`data-moment`, `data-moment-state`), in journey order, then `extra`.
  defp page(moments, extra \\ "") do
    sections =
      Enum.map_join(moments, fn {moment, state} ->
        ~s(<section id="#{moment}-step" data-moment="#{moment}" data-moment-state="#{state}"></section>)
      end)

    "<main>" <> sections <> extra <> "</main>"
  end

  # The organiser's page, or with `meeting_type` that type's own link.
  defp open(conn, profile, meeting_type \\ nil) do
    path = Enum.join(Enum.reject([profile.username, meeting_type], &is_nil/1), "/")
    {:ok, view, _html} = live(conn, "/#{path}?timezone=#{@timezone}")
    view
  end

  # The slot picker. The classic journey shows it one way on past the meeting
  # types; a custom journey shows it on the page once the type is chosen
  # (Fixture Scroll) or defaulted (Fixture Talk, Fixture Express), so no
  # step-level move is taken there.
  defp to_picker(view, :classic) do
    BookingDriver.choose_meeting_type(view, "quick-chat")
    BookingDriver.continue(view)
  end

  defp to_picker(view, :custom), do: BookingDriver.choose_meeting_type(view, "quick-chat")

  # The last day a bounded picker shows, as a day button or a slot button.
  defp last_day_on_show(view), do: view |> days_on_show() |> Enum.max()

  # The free days the picker shows, as enabled day buttons or slot buttons.
  defp days_on_show(view) do
    BookingDriver.load(view)
    doc = view |> render() |> Floki.parse_document!()

    Enum.uniq(
      Floki.attribute(doc, "[data-fact='date']:not([disabled])", "data-value") ++
        Floki.attribute(doc, "[data-fact='slot']:not([disabled])", "data-date")
    )
  end

  # At least `days` out and past the current month, whatever today is: so
  # past the period any picker opens on (today's week, today's month), and
  # within six weeks, which a week-by-week picker reaches in its six moves.
  defp past_first_period(days) do
    today = Date.utc_today()
    Enum.max([Date.add(today, days), today |> Date.end_of_month() |> Date.add(1)], Date)
  end

  # Opens the booking window to sixty days, so a day past the current month
  # is always bookable, with any other schedule changes in `changes`.
  defp widen_window(profile, changes \\ []) do
    AvailabilityScheduleSchema
    |> Repo.get_by!(profile_id: profile.id)
    |> Changeset.change(Keyword.put(changes, :advance_booking_days, 60))
    |> Repo.update!()
  end

  # A picked `{iso, "10:00 AM"}` as the meeting's start in the test's zone.
  defp at(iso, time) do
    [clock, meridiem] = String.split(time, " ")
    [hour, minute] = clock |> String.split(":") |> Enum.map(&String.to_integer/1)
    hour = rem(hour, 12) + if(meridiem == "PM", do: 12, else: 0)

    DateTime.new!(Date.from_iso8601!(iso), Time.new!(hour, minute, 0), @timezone)
  end

  defp ask_questions(user) do
    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)

    {:ok, _meeting_type} =
      MeetingTypes.update_meeting_type(meeting_type, %{
        "custom_fields" => [
          %{
            "id" => "dq-company",
            "type" => "short_text",
            "label" => "Company",
            "required" => true,
            "position" => 0
          },
          %{
            "id" => "dq-recorded",
            "type" => "yes_no",
            "label" => "May we record the call?",
            "required" => true,
            "position" => 1
          },
          %{
            "id" => "dq-topics",
            "type" => "multi_select",
            "label" => "Topics",
            "required" => true,
            "position" => 2,
            "options" => [
              %{"key" => "design", "label" => "Design"},
              %{"key" => "pricing", "label" => "Pricing"},
              %{"key" => "support", "label" => "Support"}
            ]
          }
        ]
      })

    :ok
  end

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
