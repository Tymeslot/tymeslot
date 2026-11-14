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

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Create
  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.CustomFields
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
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

    %{meeting_type: meeting_type, user: user, profile: profile}
  end

  defp book(user, meeting_type, locale, days_ahead \\ 1) do
    # The page shows the questions in the booker's language, and the snapshot
    # it submits is what the booker saw.
    snapshot =
      meeting_type
      |> ContentTranslations.localise(locale)
      |> CustomFields.snapshot_for()

    Create.execute(
      %{
        date: Date.add(Date.utc_today(), days_ahead),
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
             "de" => %{
               "meeting_type" => "Erstgespräch",
               "custom_fields_snapshot" => [%{"label" => "Firma"}]
             }
           } = meeting.attendee_texts

    assert Map.keys(meeting.attendee_texts) == ["de"]

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

  describe "when an admin moves the booking pages' fallback onto a translation language" do
    setup %{profile: profile} do
      previous = Application.fetch_env(:tymeslot, :booking_default_locale)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:tymeslot, :booking_default_locale, value)
          :error -> Application.delete_env(:tymeslot, :booking_default_locale)
        end
      end)

      # The organiser never picked an original: it was the fallback, English.
      profile
      |> Changeset.change(content_locale: nil, translation_locales: [])
      |> Repo.update!()

      :ok
    end

    defp move_fallback_to(locale),
      do: Application.put_env(:tymeslot, :booking_default_locale, locale)

    test "languages saved before the move keep their original, and German bookings their copy",
         %{user: user, profile: profile, meeting_type: meeting_type} do
      assert {:ok, _saved} =
               Profiles.update_booking_languages(Repo.get!(ProfileSchema, profile.id), %{
                 translation_locales: ["de"]
               })

      move_fallback_to("de")

      assert {:ok, meeting} = book(user, meeting_type, "de")
      assert %{"de" => %{"meeting_type" => "Erstgespräch"}} = meeting.attendee_texts

      # The organiser's next save is not refused for listing their original.
      assert {:ok, %{content_locale: "en"}} =
               Profiles.update_booking_languages(Repo.get!(ProfileSchema, profile.id), %{
                 offer_all_locales: false
               })
    end

    test "a profile never saved since keeps showing its translations, and saves again",
         %{user: user, profile: profile, meeting_type: meeting_type} do
      # A row from before the original was saved with the languages.
      ProfileSchema
      |> Repo.get!(profile.id)
      |> Changeset.change(translation_locales: ["de"])
      |> Repo.update!()

      move_fallback_to("de")

      assert {:ok, meeting} = book(user, meeting_type, "de")
      assert %{"de" => %{"meeting_type" => "Erstgespräch"}} = meeting.attendee_texts

      assert {:ok, saved} =
               Profiles.update_booking_languages(Repo.get!(ProfileSchema, profile.id), %{
                 offer_all_locales: false
               })

      assert saved.content_locale not in [nil, "de"]
      assert saved.translation_locales == ["de"]
    end
  end

  describe "an outdated translation" do
    setup %{meeting_type: meeting_type} do
      # The organiser renamed the type after translating it.
      meeting_type =
        meeting_type
        |> Changeset.change(name: "Discovery call")
        |> Repo.update!()

      %{meeting_type: meeting_type}
    end

    test "is not given to the attendee, until the organiser confirms it", %{
      user: user,
      meeting_type: meeting_type
    } do
      assert {:ok, meeting} = book(user, meeting_type, "de")

      # The question's translation is current; the name's is not.
      assert %{"de" => %{"meeting_type" => "Discovery call"} = copy} = meeting.attendee_texts
      assert [%{"label" => "Firma"}] = copy["custom_fields_snapshot"]

      attendee = confirmation_emails(meeting)["attendee@example.com"]
      assert attendee.html_body =~ "Discovery call"
      refute attendee.html_body =~ "Erstgespräch"

      assert {:ok, _entity} =
               Catalogue.confirm(user.id, {:meeting_type, meeting_type.id}, "de", ["name"])

      confirmed = Repo.get!(MeetingTypeSchema, meeting_type.id)
      assert {:ok, later} = book(user, confirmed, "de", 2)
      assert %{"de" => %{"meeting_type" => "Erstgespräch"}} = later.attendee_texts
    end
  end
end
