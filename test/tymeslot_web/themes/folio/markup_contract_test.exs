defmodule TymeslotWeb.Themes.Folio.MarkupContractTest do
  @moduledoc """
  Where Folio puts the markup contract (`docs/THEME_DEVELOPMENT_GUIDE.md`,
  §"The markup contract") on each of its moments and the confirmation:
  every day of the month on show is a `date` fact and a padded day of the
  neighbouring month is not, and the month arrows are the ways to earlier
  and later days. The moments are reached through their existing test ids, so this
  holds whatever the contract's own driver does.
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

  @theme_id "4"
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

  test "the ways to work mark each meeting type, with no way on", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "folio-mc-overview", @timezone)
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")
    doc = document(view)

    assert [_card] =
             Floki.find(
               doc,
               "#offer-step [data-testid='duration-option'][data-fact='meeting_type'][data-value='quick-chat']"
             )

    assert [_offer] = Floki.find(doc, "#offer-step[data-moment-state='current']")
    assert Floki.find(doc, "[data-intent='continue']") == []
    assert Floki.find(doc, "[data-intent='back']") == []
  end

  test "the schedule marks the month's days and arrows, and no padded day", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "folio-mc-schedule", @timezone)
    doc = conn |> open_schedule(profile) |> document()

    month_days =
      Floki.attribute(
        doc,
        "[data-testid='calendar-day']:not(.calendar-day--other-month)",
        "data-date"
      )

    assert month_days != []
    assert Floki.attribute(doc, "[data-fact='date']", "data-value") == month_days
    assert Floki.find(doc, ".calendar-day--other-month[data-fact]") == []

    assert [_prev] = Floki.find(doc, "button[phx-click='prev_month'][data-intent='earlier']")
    assert [_next] = Floki.find(doc, "button[phx-click='next_month'][data-intent='later']")
    assert Floki.find(doc, "[data-intent='back']") == []
    assert Floki.find(doc, "[data-intent='continue']") == []
  end

  test "the questions in the details mark the question and the way on", %{conn: conn} do
    %{user: user, profile: profile} =
      seed_booking_account(@theme_id, "folio-mc-questions", @timezone)

    ask_question(user)
    doc = conn |> navigate_to_booking_form(profile, nil) |> document()

    assert [_input] =
             Floki.find(doc, "#you-step [data-fact='answer'][data-question='mc-company']")

    assert [_on] =
             Floki.find(doc, "#you-step button[phx-click='next_step'][data-intent='continue']")

    assert Floki.find(doc, "[data-intent='back']") == []
  end

  test "the details mark the form and its submit", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "folio-mc-booking", @timezone)
    doc = conn |> navigate_to_booking_form(profile, nil) |> document()

    assert [_form] =
             Floki.find(doc, "#you-step form[data-testid='booking-form'][data-fact='attendee']")

    assert [_submit] =
             Floki.find(doc, "#you-step [data-testid='submit-booking'][data-intent='submit']")

    assert Floki.find(doc, "[data-intent='back']") == []
  end

  @tag :capture_log
  test "the confirmation marks its fresh start", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@theme_id, "folio-mc-done", @timezone)
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

    wait_until(fn ->
      has_element?(view, "#when-step [data-testid='calendar-day']:not([disabled])")
    end)

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
