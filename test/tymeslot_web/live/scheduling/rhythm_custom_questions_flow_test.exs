defmodule TymeslotWeb.Live.Scheduling.RhythmCustomQuestionsFlowTest do
  @moduledoc """
  The custom-questions booking wizard, walked end to end on the **Rhythm**
  theme.

  `CustomFieldsBookingFlowTest` walks this wizard on Quill and, for Rhythm,
  stops at a mount check — its own comment explains why: "A full
  booker-walks-the-wizard test would need a theme-agnostic navigation helper,
  which is out of scope here." That helper does in fact exist now:
  `BookingTestHelpers.navigate_to_booking_form/3` drives the shared
  `data-testid` attributes (`duration-option`, `next-step`, `calendar-day`)
  that *both* themes render, so the walk is available to Rhythm unchanged.

  Worth doing because the two themes do not share a component here. Each ships
  its own `CustomQuestionsComponent`, and Rhythm's was at 0% — not one of its
  29 relevant lines had ever executed. The theme dispatcher routes real bookers
  to whichever theme the organiser picked, so half the custom-questions
  audience was running rendering code no test had compiled against real data.

  One concrete difference the walk pins: Rhythm exposes the step counter only
  through an `aria-label`, where Quill renders it as visible text. A change
  that dropped that label would take Rhythm's only progress signal with it and
  Quill's tests would stay green.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live
  @moduletag :custom_fields
  @moduletag :themes

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

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
        username: "rhythm-cf-booker",
        # "2" is Rhythm — the whole point of this module.
        booking_theme: "2",
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
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

    base_meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Rhythm Chat",
        is_active: true
      )

    # Custom fields go in through the context rather than the factory: the
    # changeset is what normalises each definition into the string-keyed shape
    # `Inputs.Renderer` pattern-matches on.
    {:ok, meeting_type} =
      MeetingTypes.update_meeting_type(base_meeting_type, %{
        "custom_fields" => [
          %{
            "id" => "cf-rhythm-company",
            "type" => "short_text",
            "label" => "Company",
            "required" => true,
            "position" => 0
          },
          %{
            "id" => "cf-rhythm-topic",
            "type" => "short_text",
            "label" => "Topic",
            "required" => false,
            "position" => 1
          }
        ]
      })

    %{profile: profile, user: user, meeting_type: meeting_type}
  end

  describe "walking the Rhythm questions wizard" do
    @tag :capture_log
    test "renders the first question with its accessible step counter", %{
      conn: conn,
      profile: profile
    } do
      view = navigate_to_booking_form(conn, profile, nil)

      html = render(view)

      assert html =~ "Company"

      assert html =~ "Question 1 of 2",
             "Rhythm carries the step counter in an aria-label; losing it leaves " <>
               "screen-reader users with no sense of progress"
    end

    @tag :capture_log
    test "a required answer blocks advancing until it is filled in", %{
      conn: conn,
      profile: profile
    } do
      view = navigate_to_booking_form(conn, profile, nil)

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      assert render(view) =~ "Question 1 of 2",
             "an empty required answer must keep the booker on the same question"

      view
      |> form("form[phx-submit='next']", %{"value" => "Acme Corp"})
      |> render_change()

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      assert render(view) =~ "Question 2 of 2"
    end

    @tag :capture_log
    test "answers survive the whole wizard and land on the meeting", %{
      conn: conn,
      profile: profile
    } do
      view = navigate_to_booking_form(conn, profile, nil)

      view
      |> form("form[phx-submit='next']", %{"value" => "Acme Corp"})
      |> render_change()

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      view
      |> form("form[phx-submit='next']", %{"value" => "Pricing"})
      |> render_change()

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Rhythm Booker",
          "email" => "rhythm.cf@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      _drain = :sys.get_state(view.pid)

      [meeting] = MeetingListQueries.list_meetings_by_attendee_email("rhythm.cf@example.com")

      assert length(meeting.custom_fields_snapshot) == 2

      answers = meeting.custom_field_answers

      assert answer_for(meeting, "Company", answers) == "Acme Corp"
      assert answer_for(meeting, "Topic", answers) == "Pricing"
    end

    @tag :capture_log
    test "back-navigation from the first question returns to the schedule step", %{
      conn: conn,
      profile: profile
    } do
      view = navigate_to_booking_form(conn, profile, nil)

      assert render(view) =~ "Question 1 of 2"

      view |> element("button[phx-click='back'][phx-target]") |> render_click()

      refute render(view) =~ "Question 1 of 2",
             "back on the first question leaves the wizard rather than trapping the booker"
    end
  end

  defp answer_for(meeting, label, answers) do
    Enum.find_value(meeting.custom_fields_snapshot, fn definition ->
      if definition["label"] == label, do: answers[definition["id"]]
    end)
  end
end
