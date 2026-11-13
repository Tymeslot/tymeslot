defmodule TymeslotWeb.Dashboard.Calendar.CalendarMeetingJourneyTest do
  @moduledoc """
  A Tymeslot meeting booked from the calendar's side panel reaches its
  guests: the extra guest is invited in the language the organiser chose,
  with the note, by the organiser.
  """

  # Not async: the real email service is swapped in for the mock, and Swoosh
  # delivers to this process through a global setting.
  use TymeslotWeb.LiveCase, async: false
  use Gettext, backend: TymeslotWeb.Gettext

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :emails
  @moduletag :integration
  @moduletag :live

  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  setup %{conn: conn} do
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    context = owner(conn)
    Repo.update!(Changeset.change(context.user, name: "Olive Host"))

    context.user.id
    |> Profiles.get_profile()
    |> Changeset.change(full_name: "Olive Host")
    |> Repo.update!()

    context
  end

  defp delivered_to(address) do
    assert_received {:email, %Swoosh.Email{to: [{_name, ^address}]} = email}
    email
  end

  defp in_french(fun), do: Gettext.with_locale(TymeslotWeb.Gettext, "fr", fun)

  test "invites the extra guest in the chosen language, with the note, naming the organiser", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    # Ahead of both the frozen clock and the real one, so no email is held
    # back as being about a past meeting. 13:00 in London is 13:00 UTC in March.
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:more_options", %{
      "draft" => "d1",
      # A title of its own, so the default ("Meeting with Ada Lovelace") does
      # not put the main guest's name in the email.
      "title" => "Roadmap review",
      "start" => "2027-03-10T13:00",
      "end" => "2027-03-10T14:00",
      "all_day" => false,
      "calendar" => "#{integration.id}:work",
      "location" => "",
      "guests" => ["ada@example.com"],
      "free" => false
    })

    lv
    |> form("#calendar-panel-new-form")
    |> render_submit(%{"intent" => "add_guest", "guest_email" => "grace@example.com"})

    lv |> form("#calendar-panel-new-form") |> render_change(%{"meeting" => "true"})

    lv
    |> form("#calendar-panel-new-form")
    |> render_submit(%{
      "intent" => "create",
      "guest_name" => "Ada Lovelace",
      "locale" => "fr",
      "description" => "Agenda: the Q3 roadmap."
    })

    # The booking runs in a supervised task, so the row appears a moment later.
    meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: 5_000)

    assert %{success: success, failure: 0} = Oban.drain_queue(queue: :emails)
    assert success >= 1

    email = delivered_to("grace@example.com")

    # Written in the language chosen for the guests, not the organiser's own.
    assert email.html_body =~
             in_french(fn -> dgettext("emails_booking", "Will you be there?") end)

    assert email.text_body =~
             in_french(fn -> dgettext("emails_booking", "WILL YOU BE THERE?") end)

    refute email.text_body =~ "WILL YOU BE THERE?"

    for body <- [email.html_body, email.text_body] do
      assert body =~ "Agenda: the Q3 roadmap."
      # The organiser invited this guest: the booker's wording would name
      # Ada, the person the meeting is with, as the one inviting them.
      assert body =~ "Olive Host"
      refute body =~ "Ada Lovelace"
    end

    assert [%{email: "grace@example.com", invited_by: :organizer} = guest] =
             GuestQueries.list_for_meeting(meeting.id)

    assert %DateTime{} = guest.confirmation_sent_at
  end
end
