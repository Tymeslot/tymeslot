defmodule TymeslotWeb.Dashboard.BookingsManagementRefusalTest do
  @moduledoc """
  The host asking to cancel, reschedule, or ask to reschedule a booking the
  booking rules no longer allow: the action stops and the host is told why,
  in their own language, never with the domain's reason term or a generic
  "try again" that retrying cannot answer.

  The host here works in German, so an assertion on the copy also proves it
  went through the translated refusal rather than an English string.
  """

  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  @moduletag :bookings
  @moduletag :live

  alias Phoenix.LiveView.Socket
  alias Plug.Test
  alias Tymeslot.Meetings.MeetingQueries
  alias TymeslotWeb.Dashboard.BookingsManagementComponent

  setup :verify_on_exit!

  setup %{conn: conn} do
    stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, fn _email, _details ->
      {:ok, nil}
    end)

    stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, fn _email, _details ->
      {:ok, nil}
    end)

    host = insert(:user, onboarding_completed_at: DateTime.utc_now(:second), locale: "de")
    insert(:profile, user: host)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(host)

    {:ok, conn: conn, host: host}
  end

  test "cancelling a meeting already under way is refused with the reason", ctx do
    meeting = meeting_for(ctx.host, -10)
    view = open_meetings(ctx.conn)

    html = push_to_component(view, "show_cancel_modal", %{"id" => meeting.id})

    refute has_element?(view, "#cancel-meeting-form")
    assert html =~ "Ein bereits begonnener Termin kann nicht abgesagt werden"
  end

  test "asking to reschedule a meeting already under way is refused with the reason", ctx do
    meeting = meeting_for(ctx.host, -10)
    view = open_meetings(ctx.conn)

    html = push_to_component(view, "show_reschedule_modal", %{"id" => meeting.id})

    refute has_element?(view, "#reschedule-request-modal form")
    assert html =~ "Ein bereits begonnener Termin kann nicht verschoben werden"
  end

  # The attendee moved the booking into an approval-gated time after the
  # host opened the dialog. Sending is refused by the row as it now stands.
  test "a reschedule request the booking can no longer take says why", ctx do
    meeting = meeting_for(ctx.host, 24 * 60)
    view = open_meetings(ctx.conn)
    push_to_component(view, "show_reschedule_modal", %{"id" => meeting.id})

    {:ok, _held} = MeetingQueries.update_meeting_status(meeting, %{status: "awaiting_approval"})

    html = push_to_component(view, "confirm_reschedule_request", %{})

    assert html =~
             "Solange die Buchung noch bestätigt werden muss, kann keine Verschiebung angefragt werden"

    assert is_nil(
             MeetingQueries.get_meeting(meeting.id)
             |> elem(1)
             |> Map.get(:reschedule_requested_at)
           )
  end

  # The meeting started between the host opening the cancel dialog and
  # confirming it. The clock has to move between the two, which only a
  # frozen clock in this process can do, so the confirm runs the component's
  # handler here rather than through the page's process.
  test "a cancel confirmed after the meeting started says why", ctx do
    meeting = meeting_for(ctx.host, 30)
    Gettext.put_locale(TymeslotWeb.Gettext, "de")
    freeze_clock(DateTime.add(meeting.start_time, 5, :minute))

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        current_user: ctx.host,
        cancel_booking_payment: nil,
        cancel_meeting_modal_data: meeting,
        show_cancel_meeting_modal: true
      }
    }

    assert {:noreply, _socket} =
             BookingsManagementComponent.handle_event("confirm_cancel_meeting", %{}, socket)

    assert_received {:flash, {:error, "Ein bereits begonnener Termin kann nicht abgesagt werden"}}
    assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
  end

  defp meeting_for(host, start_in_minutes) do
    now = DateTime.utc_now(:second)
    start_time = DateTime.add(now, start_in_minutes, :minute)

    insert(:meeting,
      status: "confirmed",
      organizer_user: host,
      organizer_user_id: host.id,
      organizer_email: host.email,
      attendee_name: "Alex Guest",
      attendee_email: "alex@example.com",
      start_time: start_time,
      end_time: DateTime.add(start_time, 60, :minute)
    )
  end

  defp push_to_component(view, event, params) do
    view |> with_target("#bookings-management") |> render_click(event, params)
    render(view)
  end

  defp open_meetings(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view
  end
end
