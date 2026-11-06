defmodule TymeslotWeb.Themes.Quill.MarkupContractTest do
  @moduledoc """
  Where Quill puts the markup contract (`docs/THEME_DEVELOPMENT_GUIDE.md`,
  §"The markup contract") on each of its booking steps. Quill renders its
  days twice, a week strip for narrow screens beside the month grid, so
  both are marked and the week strip's marks also carry `data-alternate`;
  a padded day of the neighbouring month is not marked. The steps are
  reached through their existing test ids, so this holds whatever the
  contract's own driver does.
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

  test "the overview marks each meeting type, which is the way on", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "quill-mc-overview", @timezone)
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")
    doc = document(view)

    assert [_card] =
             Floki.find(
               doc,
               "[data-testid='duration-option'][data-fact='meeting_type'][data-value='quick-chat']"
             )

    assert [_overview] = Floki.find(doc, "#overview-step[data-moment-state='current']")
    assert Floki.find(doc, "#overview-step [data-intent='continue']") == []
    assert Floki.find(doc, "[data-intent='back']") == []
  end

  test "choosing a meeting type moves on, and back on the overview it shows chosen",
       %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "quill-mc-back", @timezone)
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")
    card = "[data-testid='duration-option'][data-value='quick-chat']"

    refute has_element?(view, "#{card}.duration-card--selected")

    view |> element(card) |> render_click()
    assert has_element?(view, "#schedule-step[data-moment-state='current']")

    view |> element("[data-intent='back']") |> render_click()
    assert has_element?(view, "#overview-step[data-moment-state='current']")
    assert has_element?(view, "#{card}.duration-card--selected")
  end

  test "the schedule marks the month grid's days and arrows, and the week strip's as alternates",
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

    assert Floki.attribute(doc, "[data-fact='date']:not([data-alternate])", "data-value") ==
             month_days

    week_days = Floki.attribute(doc, ".week-day-cell", "phx-value-date")
    assert length(week_days) == 7

    assert Floki.attribute(doc, ".week-day-cell[data-fact='date'][data-alternate]", "data-value") ==
             week_days

    assert [_prev] =
             Floki.find(
               doc,
               "button[phx-click='prev_month'][data-intent='earlier']:not([data-alternate])"
             )

    assert [_next] =
             Floki.find(
               doc,
               "button[phx-click='next_month'][data-intent='later']:not([data-alternate])"
             )

    assert [_prev_week] =
             Floki.find(
               doc,
               "button[phx-click='prev_week'][data-intent='earlier'][data-alternate]"
             )

    assert [_next_week] =
             Floki.find(doc, "button[phx-click='next_week'][data-intent='later'][data-alternate]")

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
