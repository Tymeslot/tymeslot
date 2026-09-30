defmodule TymeslotWeb.Dashboard.BookingsRemindersTest do
  @moduledoc """
  What a booking's card says about its reminders: which ones it carries, which
  have gone out, and the bookings that have none to show.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meetings
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Notifications.Orchestrator

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()

    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "reminders on a booking" do
    test "lists what the booking reminds with, and which have gone out", %{
      conn: conn,
      user: user
    } do
      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          attendee_name: "Ada Lovelace",
          reminders: [%{"value" => 2, "unit" => "hours"}, %{"value" => 20, "unit" => "minutes"}],
          reminders_sent: [
            %{
              "value" => 2,
              "unit" => "hours",
              "organizer_sent" => true,
              "attendee_sent" => true
            }
          ]
        )

      assert :ok = Orchestrator.schedule_reminder_notifications(meeting)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      html = render(view)

      assert html =~ "2 hours before"
      assert html =~ "20 minutes before"
      assert html =~ "Sent"
      assert html =~ "Not yet sent"
    end

    test "a reminder scheduling was refused for is not promised", %{conn: conn, user: user} do
      scheduled = reminding_booking(user, "Ada Lovelace", 1)
      refused = reminding_booking(user, "Grace Hopper", 2)

      assert :ok = Orchestrator.schedule_reminder_notifications(scheduled)

      # An incomplete recipient: the orchestrator refuses before enqueueing,
      # so no job will ever send this booking's reminder.
      assert {:error, _reason} =
               Orchestrator.schedule_reminder_notifications(%{refused | attendee_name: nil})

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      scheduled_card = view |> element("#meeting-reminders-#{scheduled.id}") |> render()
      assert scheduled_card =~ "Not yet sent"

      refused_card = view |> element("#meeting-reminders-#{refused.id}") |> render()
      assert refused_card =~ "20 minutes before"
      assert refused_card =~ "Not scheduled"
      refute refused_card =~ "Not yet sent"
    end

    test "a reminder the booking came too late for reads as not sent", %{
      conn: conn,
      user: user
    } do
      # Booked an hour ahead, so the two-hour reminder was never scheduled.
      start_time = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)

      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute),
        reminders: [%{"value" => 2, "unit" => "hours"}]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      html = render(view)

      assert html =~ "2 hours before"
      assert html =~ "Not sent"
      refute html =~ "Not yet sent"
    end

    test "a booking that asked for none shows no reminder section", %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        reminders: []
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      refute render(view) =~ "minutes before"
    end

    test "a row from before the column existed shows the reminder it still gets", %{
      conn: conn,
      user: user
    } do
      # `nil` is not "none": `Orchestrator` falls back to 30 minutes for such a
      # booking, so the list says what the guest will actually receive.
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        reminders: nil
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert render(view) =~ "30 minutes before"
    end

    test "a cancelled booking lists none: its reminder jobs went with it", %{
      conn: conn,
      user: user
    } do
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        status: "cancelled",
        reminders: [%{"value" => 20, "unit" => "minutes"}]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("button", "Cancelled") |> render_click()
      html = render(view)

      assert html =~ "Ada Lovelace"
      refute html =~ "20 minutes before"
    end

    test "a request still held for approval promises nothing yet", %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        status: "awaiting_approval",
        reminders: [%{"value" => 20, "unit" => "minutes"}]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("button", "Requests") |> render_click()
      html = render(view)

      assert html =~ "20 minutes before"
      assert html =~ "After approval"
    end
  end

  defp reminding_booking(user, attendee_name, days_ahead) do
    start_time =
      DateTime.utc_now() |> DateTime.add(days_ahead, :day) |> DateTime.truncate(:second)

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      attendee_name: attendee_name,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      reminders: [%{"value" => 20, "unit" => "minutes"}]
    )
  end
end
