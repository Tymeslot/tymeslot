defmodule TymeslotWeb.RescheduleRequestLapseWebTest do
  @moduledoc """
  Once a host's reschedule request has lapsed unanswered, the attendee's
  emailed links send them to the booking page with an explanation, and the
  host's card no longer offers to cancel it.
  """
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Bookings.RescheduleRequestExpiry
  alias Tymeslot.Repo

  @day 86_400

  setup do
    %{user: user, profile: profile} = seed_booking_account("1", "lapsedhost", "Etc/UTC")

    user =
      Repo.update!(Changeset.change(user, onboarding_completed_at: DateTime.utc_now(:second)))

    now = DateTime.utc_now(:second)

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Never Answered",
        status: :confirmed,
        start_time: DateTime.add(now, -2 * @day),
        end_time: DateTime.add(now, -2 * @day + 3_600),
        reschedule_requested_at: DateTime.add(now, -8 * @day)
      )

    %{user: user, profile: profile, meeting: meeting}
  end

  for action <- ["reschedule", "cancel"] do
    test "the attendee's #{action} link, past the deadline, points them at the booking page",
         ctx do
      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(
                 build_conn(),
                 "/#{ctx.profile.username}/meeting/#{ctx.meeting.uid}/#{unquote(action)}"
               )

      assert to == "/#{ctx.profile.username}"
      assert flash["error"] =~ "The request to pick a new time for this meeting has lapsed"
    end
  end

  test "the attendee's link still says so once the meeting has expired", ctx do
    {:ok, _expired} = RescheduleRequestExpiry.expire(ctx.meeting)

    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             live(build_conn(), "/#{ctx.profile.username}/meeting/#{ctx.meeting.uid}/reschedule")

    assert to == "/#{ctx.profile.username}"
    assert flash["error"] =~ "has lapsed"
  end

  test "the host's card shows the expired meeting with no cancel action", ctx do
    {:ok, _expired} = RescheduleRequestExpiry.expire(ctx.meeting)

    conn = build_conn() |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view |> element("button", "Past") |> render_click()

    html = render(view)
    assert html =~ "Never Answered"
    assert html =~ "Expired"
    refute has_element?(view, "#cancel-meeting-#{ctx.meeting.id}")
    refute has_element?(view, "#reschedule-meeting-#{ctx.meeting.id}")
  end

  # The deadline can be the original start itself, so a meeting can expire
  # while its original time is still running.
  test "an expired meeting whose original time has not ended offers no actions", ctx do
    now = DateTime.utc_now(:second)

    meeting =
      insert(:meeting,
        organizer_user: ctx.user,
        organizer_email: ctx.user.email,
        attendee_name: "Still Running",
        status: :confirmed,
        start_time: DateTime.add(now, -600),
        end_time: DateTime.add(now, 3_000),
        reschedule_requested_at: DateTime.add(now, -8 * @day)
      )

    {:ok, _expired} = RescheduleRequestExpiry.expire(meeting)

    conn = build_conn() |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings?meeting=#{meeting.id}")

    assert render(view) =~ "Still Running"
    refute has_element?(view, "#cancel-meeting-#{meeting.id}")
  end

  test "before the job runs, the host's cancel is already refused", ctx do
    conn = build_conn() |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view |> element("button", "Past") |> render_click()

    assert render(view) =~ "Never Answered"
    refute has_element?(view, "#cancel-meeting-#{ctx.meeting.id}:not([disabled])")
  end
end
