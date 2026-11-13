defmodule Tymeslot.Bookings.DefaultLocationLabelEmailsTest do
  @moduledoc """
  A location still carrying its default label ("In person") is product
  wording, not the organiser's text: the booking stores it once, in English,
  and every email, calendar attachment included, reads it in its
  recipient's language, whether or not the organiser translates into it. A
  label the organiser wrote is shown as written.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :emails
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.TestMocks

  @attendee "attendee@example.com"
  @organizer "organizer@example.com"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.stub_no_calendar_events()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    # Delivery runs behind the mail circuit breaker, in another process.
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    # A German-speaking organiser who translates into German only, on a
    # booking page offered in every language.
    user = insert(:user, email: @organizer, name: "Olivia Host", locale: "de")

    profile =
      insert(:profile,
        user: user,
        timezone: "America/New_York",
        content_locale: "en",
        translation_locales: ["de"]
      )

    _schedule = open_schedule_for(profile)

    %{user: user}
  end

  defp book_in_french(ctx, location) do
    meeting_type =
      insert(:meeting_type,
        user: ctx.user,
        name: "Intro call",
        duration_minutes: 30,
        locations: [location]
      )

    Gettext.with_locale(TymeslotWeb.Gettext, "fr", fn ->
      assert {:ok, meeting} =
               Create.execute(
                 %{
                   date: Date.add(Date.utc_today(), 1),
                   time: "14:00",
                   duration: "30min",
                   user_timezone: "America/New_York",
                   organizer_user_id: ctx.user.id,
                   meeting_type_id: meeting_type.id,
                   attendee_locale: "fr",
                   location_option_id: location.id
                 },
                 %{"name" => "Jeanne Invitée", "email" => @attendee, "message" => ""}
               )

      meeting
    end)
  end

  # Runs the email jobs enqueued so far, and returns the emails delivered,
  # by recipient.
  defp delivered do
    Oban.drain_queue(queue: :emails)
    collect([])
  end

  defp collect(emails) do
    receive do
      {:email, email} -> collect([email | emails])
    after
      0 -> Enum.group_by(emails, &(&1.to |> hd() |> elem(1)))
    end
  end

  defp only(emails, address) do
    assert [email] = Map.fetch!(emails, address)
    email
  end

  defp ics(email) do
    assert [%{data: data}] =
             Enum.filter(email.attachments, &String.ends_with?(&1.filename, ".ics"))

    data
  end

  test "a French invitee reads a default label in French, the organiser in German", ctx do
    meeting = book_in_french(ctx, in_person_location([], id: "loc-arranged"))

    assert meeting.location == "In person"
    assert meeting.attendee_texts == nil

    emails = delivered()
    attendee = only(emails, @attendee)
    organizer = only(emails, @organizer)

    assert attendee.html_body =~ "En personne"
    assert attendee.text_body =~ "En personne"
    assert ics(attendee) =~ "LOCATION;LANGUAGE=fr:En personne"
    refute attendee.html_body =~ "In person"

    assert organizer.html_body =~ "Vor Ort"
    refute organizer.html_body =~ "En personne"
  end

  test "a label the organiser wrote reads as written in every email", ctx do
    studio = %LocationOption{
      id: "loc-studio",
      kind: :custom,
      label: "Our studio",
      details: "Back entrance",
      position: 0
    }

    meeting = book_in_french(ctx, studio)

    assert meeting.location == "Our studio (Back entrance)"

    emails = delivered()
    assert only(emails, @attendee).html_body =~ "Our studio (Back entrance)"
    assert only(emails, @organizer).html_body =~ "Our studio (Back entrance)"
  end
end
