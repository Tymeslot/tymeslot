defmodule TymeslotWeb.Live.Themes.ThemeApprovalDisclosureTest do
  @moduledoc """
  What a visitor is told when the meeting type needs the host's approval.

  The failure this guards against is the one the whole feature exists to fix:
  a visitor who picks a time, sees "You're All Set!", and only learns from an
  email that nobody has agreed to it. Every stage of the flow is checked in
  both themes, and the confirmation screen is checked hardest, because that is
  the screen that used to lie.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers

  @moduletag :themes
  @moduletag :bookings

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  @themes %{"1" => "quill", "2" => "rhythm"}

  defp gate(user) do
    [type] = MeetingTypes.get_all_meeting_types(user.id)

    type
    |> Changeset.change(requires_approval: true, approval_window_hours: 12)
    |> Repo.update!()
  end

  for {theme_id, theme} <- @themes do
    describe "#{theme}: a gated meeting type" do
      @tag :capture_log
      test "is marked as needing approval before anything is picked", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme_id), "gated-#{unquote(theme)}", "America/New_York")

        gate(user)

        {:ok, _view, html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

        assert html =~ "data-testid=\"approval-pill\""
        assert html =~ "Needs approval"
      end

      @tag :capture_log
      test "says so on the form, and does not call the button \"Book\"", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme_id), "form-#{unquote(theme)}", "America/New_York")

        gate(user)

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

        advance_to_booking_form(view, unquote(theme))
        html = render(view)

        assert html =~ "data-testid=\"approval-notice\""
        assert html =~ "sends a request rather than booking the time outright"

        # The last thing read before committing must not promise a booking.
        submit = view |> element("[data-testid='submit-booking']") |> render()
        assert submit =~ "Request meeting"
        refute submit =~ "Book Meeting"
      end

      @tag :capture_log
      test "does not tell the visitor they are all set", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme_id), "done-#{unquote(theme)}", "America/New_York")

        gate(user)

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

        email = "held-#{unquote(theme)}@example.com"

        html =
          complete_booking_flow(view, unquote(theme), unquote(theme_id), %{
            name: "Test Attendee",
            email: email,
            message: "Hello!"
          })

        assert html =~ "Request sent!"
        assert html =~ "Not confirmed yet"
        assert html =~ "still has to accept this time"

        refute html =~ "You're All Set!"
        refute html =~ "Meeting Confirmed!"
        refute html =~ "is all set"

        # And the booking really is held, not merely described as one.
        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: email)
        assert meeting.status == "awaiting_approval"
      end
    end

    describe "#{theme}: an ordinary meeting type" do
      @tag :capture_log
      test "is unchanged and still says the booking is confirmed", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme_id), "plain-#{unquote(theme)}", "America/New_York")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

        refute render(view) =~ "data-testid=\"approval-pill\""

        email = "plain-#{unquote(theme)}@example.com"

        html =
          complete_booking_flow(view, unquote(theme), unquote(theme_id), %{
            name: "Test Attendee",
            email: email,
            message: "Hello!"
          })

        refute html =~ "data-testid=\"approval-notice\""
        refute html =~ "Request sent!"

        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: email)
        assert meeting.status == "confirmed"
      end
    end
  end
end
