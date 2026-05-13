defmodule TymeslotWeb.Dashboard.BookingsManagementTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import Mox

  alias Ecto.UUID
  alias Plug.Test
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)

    # Stub email notifications for meeting actions
    stub(Tymeslot.EmailServiceMock, :send_cancellation_emails, fn _client ->
      {{:ok, nil}, {:ok, nil}}
    end)

    stub(Tymeslot.EmailServiceMock, :send_reschedule_request, fn _client -> {:ok, nil} end)

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, profile: profile}
  end

  describe "Meetings list" do
    test "renders empty state when no meetings exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      assert render(view) =~ "No upcoming meetings"
      assert render(view) =~ "Your upcoming appointments will appear here automatically"
    end

    test "shows empty state for the past filter when no past meetings exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("button", "Past") |> render_click()

      assert render(view) =~ "No past meetings"
      assert render(view) =~ "meetings in this period yet"
    end

    test "shows empty state for the cancelled filter when no cancelled meetings exist",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("button", "Cancelled") |> render_click()

      assert render(view) =~ "No cancelled meetings"
      assert render(view) =~ "cancelled appointments to show"
    end

    test "renders upcoming meetings", %{conn: conn, user: user} do
      _meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          attendee_name: "John Doe"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert render(view) =~ "John Doe"
      assert render(view) =~ "Scheduled"
    end

    test "renders in-progress meetings with join button", %{conn: conn, user: user} do
      # Meeting started 5 minutes ago, ends in 25 minutes
      _meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Active Meeting",
          meeting_url: "https://tymeslot.com/join/active",
          start_time: DateTime.add(DateTime.utc_now(), -5, :minute),
          end_time: DateTime.add(DateTime.utc_now(), 25, :minute)
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert render(view) =~ "Active Meeting"
      assert render(view) =~ "Join Meeting"
      assert render(view) =~ "https://tymeslot.com/join/active"
    end

    test "shows Completed badge for past meetings", %{conn: conn, user: user} do
      insert(:past_meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Past Attendee"
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("button", "Past") |> render_click()

      assert render(view) =~ "Past Attendee"
      assert render(view) =~ "Completed"
    end

    test "renders attendee company when present", %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Jane Smith",
        attendee_company: "Acme Corp"
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert render(view) =~ "Jane Smith"
      assert render(view) =~ "Acme Corp"
    end

    test "renders custom-field answers when the booking has them", %{conn: conn, user: user} do
      field_id = UUID.generate()

      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Custom Fields Attendee",
        custom_fields_snapshot: [
          %{"id" => field_id, "type" => "short_text", "label" => "Company name"}
        ],
        custom_field_answers: %{field_id => "Acme Ltd"}
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      html = render(view)
      assert html =~ "Custom answers"
      assert html =~ "Company name"
      assert html =~ "Acme Ltd"
    end

    test "does not render custom answers section when booking has no custom fields",
         %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Plain Attendee",
        custom_fields_snapshot: [],
        custom_field_answers: %{}
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      refute render(view) =~ "Custom answers"
    end

    test "does not render custom answers section when all custom fields were skipped",
         %{conn: conn, user: user} do
      field_id = UUID.generate()

      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Skipped Fields Attendee",
        custom_fields_snapshot: [
          %{"id" => field_id, "type" => "short_text", "label" => "Company name"}
        ],
        custom_field_answers: %{}
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      refute render(view) =~ "Custom answers"
    end

    test "filters meetings by status", %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Upcoming Meeting"
      )

      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Cancelled Meeting",
        status: "cancelled"
      )

      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Past Meeting",
        start_time: DateTime.add(DateTime.utc_now(), -1, :day),
        end_time: DateTime.add(DateTime.utc_now(), -23, :hour)
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      # Default is upcoming
      assert render(view) =~ "Upcoming Meeting"
      refute render(view) =~ "Cancelled Meeting"
      refute render(view) =~ "Past Meeting"

      # Switch to past
      view |> element("button", "Past") |> render_click()
      assert render(view) =~ "Past Meeting"
      refute render(view) =~ "Upcoming Meeting"

      # Switch to cancelled
      view |> element("button", "Cancelled") |> render_click()
      assert render(view) =~ "Cancelled Meeting"
      refute render(view) =~ "Upcoming Meeting"
    end
  end

  describe "Meeting actions" do
    test "cancels a meeting", %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          attendee_name: "To Cancel"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert render(view) =~ "To Cancel"

      # Open cancel modal
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()
      assert render(view) =~ "Are you sure you want to cancel"

      # Confirm cancellation
      view |> element("button", "Cancel Meeting") |> render_click()

      assert render(view) =~ "Meeting cancelled successfully"
      assert render(view) =~ "No upcoming meetings"

      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.status == "cancelled"
    end

    test "dismissing the cancel modal does not cancel the meeting", %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          attendee_name: "Stay Scheduled"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()
      assert render(view) =~ "Are you sure you want to cancel"

      view |> element("button", "Keep Meeting") |> render_click()
      refute render(view) =~ "Are you sure you want to cancel"

      assert Repo.get(MeetingSchema, meeting.id).status == "confirmed"
    end

    test "disables cancel and reschedule actions for meetings that have already started",
         %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "In Progress",
          start_time: DateTime.add(DateTime.utc_now(), -5, :minute),
          end_time: DateTime.add(DateTime.utc_now(), 25, :minute)
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert has_element?(view, "#cancel-meeting-#{meeting.id}[disabled]")

      assert has_element?(
               view,
               "[phx-click='show_reschedule_modal'][phx-value-id='#{meeting.id}'][disabled]"
             )
    end

    test "sends reschedule request", %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          attendee_name: "To Reschedule"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert render(view) =~ "To Reschedule"

      # Open reschedule modal
      view |> element("button", "Reschedule") |> render_click()
      assert render(view) =~ "Send a reschedule request"

      # Confirm reschedule request
      view |> element("button", "Send Request") |> render_click()

      assert render(view) =~ "Reschedule request sent to To Reschedule"

      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.status == "reschedule_requested"
    end

    test "dismissing the reschedule modal does not send a request", %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          attendee_name: "Stay Scheduled"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("button", "Reschedule") |> render_click()
      assert render(view) =~ "Send a reschedule request to"

      view |> element("#reschedule-request-modal button", "Cancel") |> render_click()
      refute render(view) =~ "Send a reschedule request to"

      assert Repo.get(MeetingSchema, meeting.id).status == "confirmed"
    end

    test "allows cancelling a meeting with reschedule_requested status", %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Reschedule Then Cancel",
          status: "reschedule_requested"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert render(view) =~ "Reschedule Then Cancel"
      assert render(view) =~ "Reschedule Requested"

      # Should see and be able to click Cancel
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()
      assert render(view) =~ "Are you sure you want to cancel"

      view |> element("button", "Cancel Meeting") |> render_click()

      assert render(view) =~ "Meeting cancelled successfully"
      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.status == "cancelled"
    end
  end

  describe "Pagination" do
    test "loads more meetings", %{conn: conn, user: user} do
      # Insert 25 meetings (per_page is 20)
      for i <- 1..25 do
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Meeting #{i}",
          start_time: DateTime.add(DateTime.utc_now(), i, :hour)
        )
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      # Should see "Load more meetings" button
      assert has_element?(view, "button", "Load more meetings")

      # Click load more
      view |> element("button", "Load more meetings") |> render_click()

      # Should see more meetings (last one should be there now)
      assert render(view) =~ "Meeting 25"
      refute has_element?(view, "button", "Load more meetings")
    end

    test "load more appends rows without removing previously visible ones",
         %{conn: conn, user: user} do
      # Seed 25 meetings and capture the names of the first-page
      # rows. "Load more" must not replace them; the user-observable
      # invariant is that the list only grows.
      now = DateTime.utc_now()

      for i <- 1..25 do
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Attendee #{String.pad_leading(Integer.to_string(i), 2, "0")}",
          start_time: DateTime.add(now, i, :hour)
        )
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      # Snapshot the first-page names that are visible before the
      # "Load more" click. These must all remain after the click.
      first_page_html = render(view)

      first_page_names =
        for i <- 1..25,
            name = "Attendee #{String.pad_leading(Integer.to_string(i), 2, "0")}",
            first_page_html =~ name do
          name
        end

      # Sanity: the first-page sample must be a real, non-empty
      # window so the post-click assertion is meaningful. If pagination
      # ever renders zero rows on page one, the supposed regression
      # we're pinning would never surface here — fail loudly in that
      # case.
      assert length(first_page_names) >= 15

      view |> element("button", "Load more meetings") |> render_click()

      rendered_after = render(view)

      for name <- first_page_names do
        assert rendered_after =~ name,
               "Expected #{name} to still be rendered after 'Load more' click, " <>
                 "but it was removed — rows must append, not replace."
      end

      # And the new rows are present — `reset: false` semantics mean
      # the final rendered list contains both the pre-click sample
      # and the tail that was just fetched.
      assert rendered_after =~ "Attendee 25"
    end
  end
end
