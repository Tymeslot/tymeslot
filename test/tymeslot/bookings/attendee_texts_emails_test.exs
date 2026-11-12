defmodule Tymeslot.Bookings.AttendeeTextsEmailsTest do
  @moduledoc """
  A booking made in one of the organiser's translation languages, from the
  booking through the confirmation job to both emails: the booking keeps the
  original wording and an attendee copy, the attendee is written to with the
  translated meeting type name and question label, and the organiser with
  their own.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :i18n
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.ContentTranslations
  alias Tymeslot.CustomFields
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
    end)

    user = insert(:user, email: "organizer@example.com", name: "Olivia Host")

    profile =
      insert(:profile,
        user: user,
        timezone: "America/New_York",
        content_locale: "en",
        translation_locales: ["de"]
      )

    _schedule = open_schedule_for(profile)

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Intro call",
        duration_minutes: 30,
        custom_fields: [
          %FieldDefinition{id: "q-company", type: "short_text", label: "Company", position: 0}
        ],
        translations: %{
          "de" => %{
            "name" => %{"text" => "Erstgespräch", "source" => :erlang.phash2("Intro call")},
            "custom_fields/q-company/label" => %{
              "text" => "Firma",
              "source" => :erlang.phash2("Company")
            }
          }
        }
      )

    %{meeting_type: meeting_type, user: user}
  end

  defp book(user, meeting_type, locale) do
    # The page shows the questions in the booker's language, and the snapshot
    # it submits is what the booker saw.
    snapshot =
      meeting_type
      |> ContentTranslations.localise(locale)
      |> CustomFields.snapshot_for()

    Create.execute(
      %{
        date: Date.add(Date.utc_today(), 1),
        time: "14:00",
        duration: "30min",
        user_timezone: "America/New_York",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        attendee_locale: locale,
        custom_fields_snapshot: snapshot,
        custom_field_answers: %{"q-company" => "Acme"}
      },
      %{"name" => "Jana Gast", "email" => "attendee@example.com", "message" => ""}
    )
  end

  defp confirmation_emails(meeting) do
    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_confirmation_emails",
               "meeting_id" => meeting.id
             })

    assert_received {:email, one}
    assert_received {:email, other}
    Map.new([one, other], &{&1.to |> hd() |> elem(1), &1})
  end

  test "a German booking stores the attendee's copies and keeps the original", %{
    user: user,
    meeting_type: meeting_type
  } do
    assert {:ok, meeting} = book(user, meeting_type, "de")

    assert meeting.meeting_type == "Intro call"
    assert [%{"label" => "Company"}] = meeting.custom_fields_snapshot

    assert %{
             "locale" => "de",
             "meeting_type" => "Erstgespräch",
             "custom_fields_snapshot" => [%{"label" => "Firma"}]
           } = meeting.attendee_texts

    emails = confirmation_emails(meeting)
    attendee = emails["attendee@example.com"]
    organizer = emails["organizer@example.com"]

    assert attendee.html_body =~ "Erstgespräch"
    assert attendee.html_body =~ "Firma"
    refute attendee.html_body =~ "Intro call"

    assert organizer.html_body =~ "Intro call"
    assert organizer.html_body =~ "Company"
    refute organizer.html_body =~ "Erstgespräch"
    refute organizer.html_body =~ "Firma"

    attendee_details = AppointmentBuilder.from_meeting(meeting)
    organizer_details = AppointmentBuilder.organizer_copy(attendee_details, meeting)

    assert attendee_details.title =~ "Erstgespräch"
    assert organizer_details.title == meeting.title
    assert organizer_details.summary == meeting.title
  end

  test "a booking in a language that is not a translation language stores no copy", %{
    user: user,
    meeting_type: meeting_type
  } do
    assert {:ok, meeting} = book(user, meeting_type, "fr")

    assert meeting.attendee_texts == nil
    assert confirmation_emails(meeting)["attendee@example.com"].html_body =~ "Intro call"
  end
end
