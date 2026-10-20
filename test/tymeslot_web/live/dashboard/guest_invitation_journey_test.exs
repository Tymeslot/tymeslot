defmodule TymeslotWeb.Dashboard.GuestInvitationJourneyTest do
  @moduledoc """
  A guest the host invites from the dashboard's Add Guests dialog on a
  booking that already exists, from the host's click to the email in the
  guest's inbox. The host is the one inviting, so the email names the host,
  not the person the meeting is with. (Inviting guests to a meeting made in
  the calendar's meeting mode is covered with that mode's tests.)
  """

  # Not async: the real email service is swapped in for the mock, and Swoosh
  # delivers to this process through a global setting.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :meetings
  @moduletag :emails
  @moduletag :integration
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now(), name: "Olive Host")
    _profile = insert(:profile, user: user, full_name: "Olive Host", timezone: "Etc/UTC")

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp delivered_to(address) do
    assert_received {:email, %Swoosh.Email{to: [{_name, ^address}]} = email}
    email
  end

  describe "the Add Guests dialog" do
    test "invites the new guest, naming the host", %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          organizer_name: "Olive Host",
          attendee_name: "John Doe",
          attendee_email: "john@example.com",
          organizer_email_sent: true,
          attendee_email_sent: true,
          start_time: DateTime.add(DateTime.utc_now(), 2, :day),
          end_time: DateTime.add(DateTime.utc_now(), 2 * 24 * 60 + 30, :minute)
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#add-guests-#{meeting.id}") |> render_click()
      view |> form("#stage-guest-form", %{"email" => "colleague@example.com"}) |> render_submit()
      view |> element("button", "Send invitation") |> render_click()

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :emails)

      email = delivered_to("colleague@example.com")

      assert email.text_body =~ "Olive Host has invited you as a guest to this meeting."
      assert email.html_body =~ "Olive Host has invited you as a guest to this meeting."

      for body <- [email.html_body, email.text_body], do: refute(body =~ "John Doe")

      # Only the new guest was written to.
      refute_received {:email, _other}
    end
  end
end
