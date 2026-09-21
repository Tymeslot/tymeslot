defmodule TymeslotWeb.Live.Scheduling.RescheduleCustomAnswersTest do
  @moduledoc """
  A reschedule arrives at the questions step with the answers of the booking it
  is moving already filled in.

  The step is still shown rather than skipped: the booker sees what is about to
  be sent in their name and can change it, and a booking being moved is exactly
  the moment an answer like "what is it about" may have changed. What they must
  not have to do is type it all again — their name, email and message are
  prefilled right beside, so leaving the organiser's own questions blank made
  the reschedule look like a fresh booking.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :live
  @moduletag :custom_fields
  @moduletag :scheduling

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.CustomFields
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  @question_id "cf-topic-001"

  defp question(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => @question_id,
        "type" => "short_text",
        "label" => "What is it about?",
        "required" => true,
        "position" => 0
      },
      overrides
    )
  end

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "reschedule-answers",
        booking_theme: "1",
        timezone: "Etc/UTC"
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

    {:ok, meeting_type} =
      MeetingTypes.update_meeting_type(
        insert(:meeting_type, user: user, duration_minutes: 30, is_active: true, slug: "consult"),
        %{"custom_fields" => [question()]}
      )

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  # The snapshot is built the way a real booking builds it — from the meeting
  # type itself — so this covers the normalisation too: a hand-written map can
  # differ from what `CustomFields.snapshot_for/1` produces for the same
  # question, and then nothing would ever be carried over.
  defp booking_answered(user, meeting_type, snapshot) do
    start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    insert(:meeting,
      organizer_user_id: user.id,
      organizer_email: user.email,
      meeting_type_id: meeting_type.id,
      duration: 30,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      custom_fields_snapshot: snapshot,
      custom_field_answers: %{@question_id => "Contract renewal"}
    )
  end

  defp deep_link_to_booking(ctx, reschedule_uid) do
    query =
      URI.encode_query(%{"timezone" => "Etc/UTC", "reschedule_meeting_uid" => reschedule_uid})

    {:ok, view, _html} =
      live(ctx.conn, "/#{ctx.profile.username}/#{ctx.meeting_type.slug}/book?#{query}")

    view
  end

  @tag :capture_log
  test "the questions step opens with the booked answer filled in", ctx do
    meeting =
      booking_answered(ctx.user, ctx.meeting_type, CustomFields.snapshot_for(ctx.meeting_type))

    view =
      navigate_to_booking_form(ctx.conn, ctx.profile, nil, reschedule_meeting_uid: meeting.uid)

    html = render(view)

    assert html =~ "What is it about?",
           "the reschedule must still be asked the organiser's questions"

    assert html =~ "Contract renewal",
           "the answer given when the booking was made must be carried over"
  end

  @tag :capture_log
  test "a question the host has edited since is asked again, blank", ctx do
    # Booked under the old wording; the host has since rewritten the question,
    # so the stored answer belongs to a question that no longer exists.
    booked_snapshot = CustomFields.snapshot_for(ctx.meeting_type)
    meeting = booking_answered(ctx.user, ctx.meeting_type, booked_snapshot)

    {:ok, _edited} =
      MeetingTypes.update_meeting_type(ctx.meeting_type, %{
        "custom_fields" => [question(%{"label" => "Anything I should know?"})]
      })

    view =
      navigate_to_booking_form(ctx.conn, ctx.profile, nil, reschedule_meeting_uid: meeting.uid)

    html = render(view)

    assert html =~ "Anything I should know?"
    refute html =~ "Contract renewal"
  end

  # `/:username/:slug/book` is directly enterable, and is where both a
  # reschedule deep-link and a mid-flow locale switch land. The engine is
  # built during `mount`, before `handle_params` has read the uid out of the
  # query string, and is then memoised on its definitions — so an engine built
  # blank here stays blank for the life of the LiveView.
  @tag :capture_log
  test "a reschedule deep-link carries the answer too", ctx do
    meeting =
      booking_answered(ctx.user, ctx.meeting_type, CustomFields.snapshot_for(ctx.meeting_type))

    html = render(deep_link_to_booking(ctx, meeting.uid))

    assert html =~ "What is it about?"
    assert html =~ "Contract renewal"
  end

  # The carried answers validate, so nothing in the required-field gate would
  # stop the deep-link entry handing them straight to the booking step and
  # submitting them in the booker's name without ever showing them.
  @tag :capture_log
  test "the questions step is shown even when every carried answer validates", ctx do
    {:ok, meeting_type} =
      MeetingTypes.update_meeting_type(ctx.meeting_type, %{
        "custom_fields" => [question(%{"required" => false})]
      })

    meeting = booking_answered(ctx.user, meeting_type, CustomFields.snapshot_for(meeting_type))

    html = render(deep_link_to_booking(ctx, meeting.uid))

    assert html =~ "What is it about?",
           "an optional question whose answer was carried must still be shown"

    assert html =~ "Contract renewal"
  end

  @tag :capture_log
  test "a fresh booking is not given anyone's answers", ctx do
    _other_booking =
      booking_answered(ctx.user, ctx.meeting_type, CustomFields.snapshot_for(ctx.meeting_type))

    view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)

    html = render(view)

    assert html =~ "What is it about?"
    refute html =~ "Contract renewal"
  end
end
