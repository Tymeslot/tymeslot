defmodule TymeslotWeb.Themes.Quill.MarkupContractTest do
  @moduledoc """
  Where Quill puts the markup contract (`docs/THEME_DEVELOPMENT_GUIDE.md`,
  §"The markup contract") on each of its booking steps. Quill renders its
  days twice, a week strip for narrow screens beside the month grid, so
  only the month grid and its arrows are marked, and a padded day of the
  neighbouring month is not. The steps are reached through their existing
  test ids, so this holds whatever the contract's own driver does.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :scheduling

  import Mox

  import Tymeslot.BookingTestHelpers,
    only: [navigate_to_booking_form: 3, seed_booking_account: 3]

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @theme_id "1"
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
    %{profile: profile} = seed_booking_account(@theme_id, "quill-mc-overview", @timezone)
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")
    doc = document(view)

    assert [_card] =
             Floki.find(
               doc,
               "[data-testid='duration-option'][data-fact='meeting_type'][data-value='quick-chat']"
             )

    assert [_next] = Floki.find(doc, "[data-testid='next-step'][data-intent='continue']")
    assert Floki.find(doc, "[data-intent='back']") == []
  end

  test "the schedule marks the month grid's days and arrows, never the week strip's",
       %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "quill-mc-schedule", @timezone)
    doc = conn |> open_schedule(profile) |> document()

    month_days =
      Floki.attribute(
        doc,
        "[data-testid='calendar-day']:not(.calendar-day--other-month)",
        "data-date"
      )

    assert month_days != []
    assert Floki.attribute(doc, "[data-fact='date']", "data-value") == month_days

    assert Floki.find(doc, ".week-day-cell") != []
    assert Floki.find(doc, ".week-day-cell[data-fact]") == []
    assert Floki.find(doc, ".weekly-nav-row button") != []
    assert Floki.find(doc, ".weekly-nav-row [data-intent]") == []

    assert [_prev] = Floki.find(doc, "button[phx-click='prev_month'][data-intent='earlier']")
    assert [_next] = Floki.find(doc, "button[phx-click='next_month'][data-intent='later']")
    assert [_back] = Floki.find(doc, "[data-testid='back-step'][data-intent='back']")
    assert [_on] = Floki.find(doc, "[data-testid='next-step'][data-intent='continue']")
  end

  test "the questions step marks the question and the ways back and on", %{conn: conn} do
    %{user: user, profile: profile} =
      seed_booking_account(@theme_id, "quill-mc-questions", @timezone)

    ask_question(user)
    doc = conn |> navigate_to_booking_form(profile, nil) |> document()

    assert [_input] = Floki.find(doc, "[data-fact='answer'][data-question='mc-company']")
    assert [_back] = Floki.find(doc, "button[phx-click='back_step'][data-intent='back']")
    assert [_on] = Floki.find(doc, "button[phx-click='next_step'][data-intent='continue']")
  end

  test "the booking step marks the form, its submit and the way back", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "quill-mc-booking", @timezone)
    doc = conn |> navigate_to_booking_form(profile, nil) |> document()

    assert [_form] = Floki.find(doc, "form[data-testid='booking-form'][data-fact='attendee']")
    assert [_submit] = Floki.find(doc, "[data-testid='submit-booking'][data-intent='submit']")
    assert [_back] = Floki.find(doc, "[data-testid='back-step'][data-intent='back']")
  end

  @tag :capture_log
  test "the confirmation marks its fresh start", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "quill-mc-done", @timezone)
    view = navigate_to_booking_form(conn, profile, nil)

    view
    |> form("form[data-testid='booking-form']", %{
      "booking" => %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => ""}
    })
    |> render_submit()

    wait_until(fn -> has_element?(view, "[data-testid='confirmation-heading']") end, 10_000)

    assert has_element?(view, "[data-testid='schedule-another'][data-intent='restart']")
  end

  defp open_schedule(conn, profile) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")
    view |> element("[data-testid='duration-option']") |> render_click()
    view |> element("[data-testid='next-step']") |> render_click()
    wait_until(fn -> has_element?(view, "[data-testid='calendar-day']:not([disabled])") end)
    view
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

  defp document(view), do: view |> render() |> Floki.parse_document!()
end
