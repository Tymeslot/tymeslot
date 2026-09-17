defmodule TymeslotWeb.Dashboard.BookingsManagementCrossTenantTest do
  @moduledoc """
  Cancelling and rescheduling somebody else's meeting.

  `Meetings.get_meeting_for_user/2` loads the row first and checks ownership
  afterwards, so the guarantee lives in the caller, not in the query. Nothing
  about the markup constrains the id: the buttons are rendered from the host's
  own list, but the event carries a client-supplied meeting id, and a crafted
  socket frame can carry any id at all. These tests push exactly that frame.

  Each refusal is paired with a positive control on the same event, because a
  test that only asserts "no modal opened" passes just as well when the event
  never reached the handler.
  """

  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  @moduletag :live
  @moduletag :meetings
  @moduletag :cross_tenant

  alias Plug.Test
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    stub(Tymeslot.EmailServiceMock, :send_cancellation_emails, fn _client ->
      {{:ok, nil}, {:ok, nil}}
    end)

    stub(Tymeslot.EmailServiceMock, :send_reschedule_request, fn _client -> {:ok, nil} end)

    host = onboarded_user()
    stranger = onboarded_user()

    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(host)

    {:ok, conn: conn, host: host, stranger: stranger}
  end

  defp onboarded_user do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    user
  end

  defp meeting_for(user, attrs \\ %{}) do
    defaults = %{
      status: "confirmed",
      organizer_user: user,
      organizer_user_id: user.id,
      organizer_email: user.email,
      attendee_name: "Alex Guest",
      attendee_email: "alex-#{System.unique_integer([:positive])}@example.com",
      start_time: DateTime.add(DateTime.utc_now(:second), 5, :day),
      end_time: DateTime.add(DateTime.utc_now(:second), 5 * 24 * 60 + 30, :minute)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  # The handlers live in a LiveComponent, so the forged event has to be pushed
  # at the component rather than at the page, which is what a crafted client
  # frame does. No rendered element carries a foreign id, so `element/2` cannot
  # be used to get there.
  defp push_to_component(view, event, params) do
    view |> with_target("#bookings-management") |> render_click(event, params)
  end

  defp open_meetings(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view
  end

  # The wrapper div is rendered whether the modal is open or shut; only the
  # inner form is gated on the modal's data assign, so it is the form that
  # answers "did this actually open?".
  defp cancel_modal_open?(view), do: has_element?(view, "#cancel-meeting-form")

  # The reschedule modal's footer buttons render whether or not it is open, so
  # the only honest signal is the body copy, which is gated on the meeting.
  defp reschedule_modal_open?(view), do: render(view) =~ "Send a reschedule request to"

  describe "cancelling somebody else's meeting" do
    test "the host's own meeting opens the cancel modal", %{conn: conn, host: host} do
      mine = meeting_for(host)

      view = open_meetings(conn)
      push_to_component(view, "show_cancel_modal", %{"id" => mine.id})

      assert cancel_modal_open?(view),
             "the control must open, or the refusals below prove nothing"
    end

    test "a meeting id belonging to another host is refused", %{
      conn: conn,
      stranger: stranger
    } do
      theirs = meeting_for(stranger)

      view = open_meetings(conn)
      push_to_component(view, "show_cancel_modal", %{"id" => theirs.id})

      refute cancel_modal_open?(view)
      assert reload(theirs).status == "confirmed"
    end

    test "and the stranger's invitee is not named on the page either", %{
      conn: conn,
      stranger: stranger
    } do
      # The modal names the invitee, so that name is what a successful forge
      # would disclose. Asserting on a field the modal never renders would pass
      # whether or not the check held.
      theirs = meeting_for(stranger, %{attendee_name: "Confidential Invitee"})

      view = open_meetings(conn)
      push_to_component(view, "show_cancel_modal", %{"id" => theirs.id})

      refute render(view) =~ "Confidential Invitee"
    end

    test "confirming a cancel that was never opened cancels nothing", %{
      conn: conn,
      stranger: stranger
    } do
      theirs = meeting_for(stranger)

      view = open_meetings(conn)

      # The confirm handler reads the meeting from the modal's own assign, so a
      # forged confirm carrying a foreign id has nothing to act on. Pinning it
      # here means a refactor that "simplifies" the handler into reading the id
      # from params fails this test rather than shipping.
      view
      |> with_target("#bookings-management")
      |> render_submit("confirm_cancel_meeting", %{"id" => theirs.id})

      assert reload(theirs).status == "confirmed"
    end
  end

  describe "rescheduling somebody else's meeting" do
    test "the host's own meeting opens the reschedule modal", %{conn: conn, host: host} do
      mine = meeting_for(host)

      view = open_meetings(conn)
      push_to_component(view, "show_reschedule_modal", %{"id" => mine.id})

      assert reschedule_modal_open?(view),
             "the control must open, or the refusal below proves nothing"
    end

    test "a meeting id belonging to another host is refused", %{
      conn: conn,
      stranger: stranger
    } do
      theirs = meeting_for(stranger)

      view = open_meetings(conn)
      push_to_component(view, "show_reschedule_modal", %{"id" => theirs.id})

      refute reschedule_modal_open?(view)
      assert reload(theirs).reschedule_requested_at == nil
    end

    test "confirming a reschedule that was never opened requests nothing", %{
      conn: conn,
      stranger: stranger
    } do
      theirs = meeting_for(stranger)

      view = open_meetings(conn)
      push_to_component(view, "confirm_reschedule_request", %{"id" => theirs.id})

      assert reload(theirs).reschedule_requested_at == nil
    end
  end

  describe "the attendee's own booking" do
    # `get_meeting_for_user/2` matches the organizer address *or* the attendee
    # address, so a signed-in user who was booked as the attendee of somebody
    # else's meeting can cancel it from their dashboard. That is deliberate —
    # it is their meeting too — but it is the one case where "belongs to another
    # host" and "may not be touched" come apart, so it is pinned rather than
    # left to be rediscovered as a suspected hole.
    test "an attendee may cancel the meeting they are booked on", %{
      conn: conn,
      host: host,
      stranger: stranger
    } do
      booked_on = meeting_for(stranger, %{attendee_email: host.email})

      view = open_meetings(conn)
      push_to_component(view, "show_cancel_modal", %{"id" => booked_on.id})

      assert cancel_modal_open?(view)
    end

    test "but a third party who is neither organizer nor attendee may not", %{conn: conn} do
      outsider = onboarded_user()
      theirs = meeting_for(outsider, %{attendee_email: "someone-else@example.com"})

      view = open_meetings(conn)
      push_to_component(view, "show_cancel_modal", %{"id" => theirs.id})

      refute cancel_modal_open?(view)
      assert reload(theirs).status == "confirmed"
    end
  end
end
