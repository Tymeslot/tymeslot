defmodule TymeslotWeb.Live.Scheduling.LongSingleSelectFlowTest do
  @moduledoc """
  A single-choice question with more than five options renders as a native
  select instead of option cards. The booker's choice has to reach the engine
  and the meeting like any other answer, in every theme.

  The walk changes the select through its form, as the browser does:
  LiveViewTest would also accept a change on a bare select, but LiveView's
  client refuses one ("form events require the input to be inside a form"),
  so only the form path proves the answer is committed.
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
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  @question_id "cf-long-select"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()
    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.slug}: a single-choice question with many options" do
      @tag :capture_log
      test "keeps the chosen option through to the meeting", %{conn: conn} do
        profile = seed_organiser(unquote(theme.id), "long-select-#{unquote(theme.slug)}")
        view = navigate_to_booking_form(conn, profile, nil)

        # Required: without the answer committed, "next" stays on the question.
        view
        |> form("#cq-form-#{@question_id}", %{"value" => "k3"})
        |> render_change()

        view |> element("button[phx-click='next_step'][phx-target]") |> render_click()

        email = "long-select.#{unquote(theme.slug)}@example.com"

        view
        |> form("form[phx-submit='submit']", %{
          "booking" => %{"name" => "Select Booker", "email" => email, "message" => ""}
        })
        |> render_submit()

        _drain = :sys.get_state(view.pid)

        assert has_element?(view, ".custom-answers__value", "Option 3")

        [meeting] = Repo.all_by(MeetingSchema, attendee_email: email)
        assert meeting.custom_field_answers[@question_id] == "k3"
      end
    end
  end

  defp seed_organiser(theme_id, username) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: username,
        booking_theme: theme_id,
        timezone: "America/New_York"
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

    for day_of_week <- 1..7 do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    insert(:calendar_integration, user: user, is_active: true)

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Select Chat",
        is_active: true
      )

    # Through the context, not the factory: the changeset normalises each
    # definition into the string-keyed shape `Inputs.Renderer` matches on.
    {:ok, _meeting_type} =
      MeetingTypes.update_meeting_type(meeting_type, %{
        "custom_fields" => [
          %{
            "id" => @question_id,
            "type" => "single_select",
            "label" => "Region",
            "required" => true,
            "position" => 0,
            "options" => for(i <- 1..6, do: %{"key" => "k#{i}", "label" => "Option #{i}"})
          }
        ]
      })

    profile
  end
end
