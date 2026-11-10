defmodule TymeslotWeb.Live.Scheduling.SinglePhoneLocationFlowTest do
  @moduledoc """
  End-to-end integration test, on every shipped theme, for a meeting type
  whose only location is a phone call asking for the booker's number.

  There is no location to choose, but the number still has to be asked for:
  the field and its error must be on the page, on a new booking and on a
  reschedule, or the form can never be submitted. `LocationChoiceFlowTest`
  covers the same number field beside other locations.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
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

    %{user: user, profile: profile} =
      seed_booking_account(Map.fetch!(tags, :theme), "phonebooker", "America/New_York")

    # The seeded default type has no phone location; this page offers one
    # type only, so that the walk cannot land anywhere else.
    Repo.delete!(Repo.get_by!(MeetingTypeSchema, user_id: user.id))

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Call me",
        is_active: true,
        locations: [
          %LocationOption{
            id: "loc-call",
            kind: :phone,
            label: "Phone call",
            collect_from_guest: true,
            position: 0
          }
        ]
      )

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  defp submit(view, email) do
    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => "Booker", "email" => email, "message" => ""}
    })
    |> render_submit()

    _drain = :sys.get_state(view.pid)
    :ok
  end

  defp type_number(view, number) do
    view
    |> form("#location-phone-form", %{"location_phone" => number})
    |> render_change()
  end

  defp confirmed?(view), do: has_element?(view, "[data-testid='confirmation-heading']")

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}: booking" do
      @describetag theme: theme.id

      @tag :capture_log
      test "asks for the number without offering a choice of location",
           %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        assert has_element?(view, "[data-testid='location-phone']")
        refute has_element?(view, "[data-testid='location-option']")
      end

      @tag :capture_log
      test "submitting without the number shows why it was refused",
           %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        submit(view, "nophone@example.com")

        assert has_element?(
                 view,
                 "[data-testid='location-error']",
                 "Enter the number we should call you on."
               )

        refute confirmed?(view)
        assert Repo.all_by(MeetingSchema, attendee_email: "nophone@example.com") == []
      end

      @tag :capture_log
      test "the number typed into the field reaches the meeting",
           %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        type_number(view, "+1 555 0100")
        submit(view, "phone@example.com")

        assert confirmed?(view)

        assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "phone@example.com")
        assert meeting.location == "Phone call (+1 555 0100)"
        assert meeting.location_kind == :phone
        assert meeting.location_option_id == "loc-call"
        assert meeting.attendee_phone == "+1 555 0100"
      end
    end

    describe "#{theme.name}: rescheduling" do
      @describetag theme: theme.id

      setup %{user: user, meeting_type: meeting_type} do
        start = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

        meeting =
          insert(:meeting,
            organizer_user_id: user.id,
            meeting_type_id: meeting_type.id,
            attendee_name: "Booker",
            attendee_email: "rebook@example.com",
            attendee_timezone: "America/New_York",
            start_time: start,
            end_time: DateTime.add(start, 30, :minute),
            duration: 30,
            status: :confirmed,
            location: "Phone call (+1 555 0100)",
            location_kind: :phone,
            location_option_id: "loc-call",
            attendee_phone: "+1 555 0100"
          )

        %{meeting: meeting, original_start: start}
      end

      @tag :capture_log
      test "opens on the number the meeting has, and a time-only move keeps it",
           %{conn: conn, profile: profile, meeting: meeting, original_start: original_start} do
        view = navigate_to_booking_form(conn, profile, nil, reschedule_meeting_uid: meeting.uid)

        assert has_element?(view, "[data-testid='location-phone'][value='+1 555 0100']")

        moved = reschedule(view, meeting, original_start)

        assert moved.location == "Phone call (+1 555 0100)"
        assert moved.attendee_phone == "+1 555 0100"
      end

      @tag :capture_log
      test "a new number replaces the one on the meeting",
           %{conn: conn, profile: profile, meeting: meeting, original_start: original_start} do
        view = navigate_to_booking_form(conn, profile, nil, reschedule_meeting_uid: meeting.uid)

        type_number(view, "+1 555 0199")
        moved = reschedule(view, meeting, original_start)

        assert moved.location == "Phone call (+1 555 0199)"
        assert moved.attendee_phone == "+1 555 0199"
      end
    end
  end

  defp reschedule(view, meeting, original_start) do
    submit(view, meeting.attendee_email)

    wait_until(fn ->
      Repo.get!(MeetingSchema, meeting.id).start_time != original_start
    end)

    Repo.get!(MeetingSchema, meeting.id)
  end
end
