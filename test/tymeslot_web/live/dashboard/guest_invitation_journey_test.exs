defmodule TymeslotWeb.Dashboard.GuestInvitationJourneyTest do
  @moduledoc """
  A guest the host invites from the dashboard, from the host's click to the
  email in the guest's inbox.

  Two ways in: a Quick Add meeting with extra guests, a note and a language
  chosen for them, and the Add Guests dialog on a booking that already
  exists. Either way the host is the one inviting, so the email names the
  host, not the person the meeting is with.
  """

  # Not async: the real email service is swapped in for the mock, and Swoosh
  # delivers to this process through a global setting.
  use TymeslotWeb.LiveCase, async: false
  use Gettext, backend: TymeslotWeb.Gettext

  @moduletag :meetings
  @moduletag :emails
  @moduletag :integration
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

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

  defp hook(lv, event, params), do: lv |> element("#calendar-grid") |> render_hook(event, params)

  defp delivered_to(address) do
    assert_received {:email, %Swoosh.Email{to: [{_name, ^address}]} = email}
    email
  end

  defp in_french(fun), do: Gettext.with_locale(TymeslotWeb.Gettext, "fr", fun)

  describe "a Quick Add meeting with extra guests" do
    test "invites them in the chosen language, with the note, naming the host", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      hook(lv, "show_create_form", %{})
      hook(lv, "update_create_guest_name", %{"value" => "Ada Lovelace"})
      hook(lv, "update_create_guest_email", %{"value" => "ada@example.com"})
      # A title of its own, so the default ("Meeting with Ada Lovelace") does
      # not put the main guest's name in the email.
      hook(lv, "update_create_title", %{"value" => "Roadmap review"})

      lv |> form("#create-add-guest-form", %{"email" => "grace@example.com"}) |> render_submit()
      lv |> element(~s(#create-meeting-locale button[phx-value-locale="fr"])) |> render_click()
      lv |> element(~s([data-testid="create-meeting-add-note"])) |> render_click()
      hook(lv, "update_create_note", %{"value" => "Agenda: the Q3 roadmap."})

      hook(lv, "save_event", %{})
      # Creation runs in a supervised task, so the row appears a moment later.
      meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: 5000)

      assert %{success: success, failure: 0} = Oban.drain_queue(queue: :emails)
      assert success >= 1

      email = delivered_to("grace@example.com")

      # Written in the language the host chose for the guests, not in the
      # host's own.
      assert email.html_body =~
               in_french(fn -> dgettext("emails_booking", "Will you be there?") end)

      assert email.text_body =~
               in_french(fn -> dgettext("emails_booking", "WILL YOU BE THERE?") end)

      refute email.text_body =~ "WILL YOU BE THERE?"

      for body <- [email.html_body, email.text_body] do
        assert body =~ "Agenda: the Q3 roadmap."
        # The host invited this guest: the booker's wording would name Ada,
        # the person the meeting is with, as the one inviting them.
        assert body =~ "Olive Host"
        refute body =~ "Ada Lovelace"
      end

      assert [%{email: "grace@example.com", invited_by: :organizer} = guest] =
               GuestQueries.list_for_meeting(meeting.id)

      assert %DateTime{} = guest.confirmation_sent_at
    end
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
