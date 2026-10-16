defmodule TymeslotWeb.Themes.FixtureThemeMarkupTest do
  @moduledoc """
  The fixture theme's steps carry the markup contract
  (`docs/THEME_DEVELOPMENT_GUIDE.md`, §"The markup contract"), and its
  questions step asks the meeting type's questions, so a fixture booking
  with questions can be made. The showcase theme renders the same steps.
  The steps are reached through their existing test ids; the week grid's
  `load_week` is sent by hand, since LiveViewTest runs no JS bindings.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :scheduling

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @theme_id "99"
  @timezone "Etc/UTC"

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

  test "the overview marks each meeting type and the way on", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "fixture-mc-overview", @timezone)
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")

    assert has_element?(
             view,
             "[data-testid='duration-option'][data-fact='meeting_type'][data-value='quick-chat']"
           )

    assert has_element?(view, "[data-testid='next-step'][data-intent='continue']")
  end

  test "the schedule marks the ways back and on", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "fixture-mc-schedule", @timezone)
    view = open_schedule(conn, profile)

    assert has_element?(view, "[data-testid='fixture-schedule'] [data-fact='slot']")
    assert has_element?(view, "[data-testid='back-step'][data-intent='back']")
    assert has_element?(view, "[data-testid='next-step'][data-intent='continue']")
  end

  @tag :capture_log
  test "the questions step asks the question, marked, and moves on once answered",
       %{conn: conn} do
    %{user: user, profile: profile} =
      seed_booking_account(@theme_id, "fixture-mc-questions", @timezone)

    ask_question(user)
    view = open_schedule(conn, profile)
    pick_first_week_slot(view)

    assert has_element?(
             view,
             "[data-testid='fixture-questions'] form[data-fact='answer'][data-question='mc-company']"
           )

    assert has_element?(view, "[data-testid='fixture-questions'] [data-intent='back']")
    assert has_element?(view, "[data-testid='fixture-questions'] [data-intent='continue']")

    view
    |> form("form[data-fact='answer'][data-question='mc-company']", %{"value" => "Acme Corp"})
    |> render_change()

    _drain = :sys.get_state(view.pid)

    view
    |> element("[data-testid='fixture-questions'] [data-intent='continue']")
    |> render_click()

    wait_until(fn -> has_element?(view, "form[data-testid='booking-form']") end)
  end

  @tag :capture_log
  test "the booking step marks its submit and the way back; the confirmation its fresh start",
       %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "fixture-mc-booking", @timezone)
    view = open_schedule(conn, profile)
    pick_first_week_slot(view)

    assert has_element?(view, "form[data-testid='booking-form'][data-fact='attendee']")
    assert has_element?(view, "[data-testid='submit-booking'][data-intent='submit']")
    assert has_element?(view, "[data-testid='fixture-booking'] [data-intent='back']")

    view
    |> form("form[data-testid='booking-form']", %{
      "booking" => %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => ""}
    })
    |> render_submit()

    wait_until(fn -> has_element?(view, "[data-testid='fixture-confirmation']") end, 10_000)

    assert has_element?(view, "[data-testid='fixture-confirmation'] [data-intent='restart']")
  end

  # Overview, schedule step, and the week loaded as the grid's phx-mounted
  # binding would load it, once the month's availability has landed the
  # booker on their first free day.
  defp open_schedule(conn, profile) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")
    view |> element("[data-testid='duration-option']") |> render_click()
    view |> element("[data-testid='next-step']") |> render_click()

    wait_until(fn ->
      :sys.get_state(view.pid).socket.assigns[:availability_status] in [:loaded, :error]
    end)

    view |> with_target("[data-testid='fixture-schedule']") |> render_click("load_week", %{})

    wait_until(fn ->
      render_async(view)
      has_element?(view, "[data-testid='week-slot']:not([disabled])")
    end)

    view
  end

  defp pick_first_week_slot(view) do
    [slot | _rest] =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[data-testid='week-slot']:not([disabled])")

    [date] = Floki.attribute(slot, "data-date")
    [time] = Floki.attribute(slot, "data-time")

    view
    |> element("[data-testid='week-slot'][data-date='#{date}'][data-time='#{time}']")
    |> render_click()

    view |> element("[data-testid='next-step']") |> render_click()
  end

  defp ask_question(user) do
    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)

    {:ok, _meeting_type} =
      MeetingTypes.update_meeting_type(meeting_type, %{
        "custom_fields" => [
          %{
            "id" => "mc-company",
            "type" => "short_text",
            "label" => "Company",
            "required" => true,
            "position" => 0
          }
        ]
      })

    :ok
  end
end
