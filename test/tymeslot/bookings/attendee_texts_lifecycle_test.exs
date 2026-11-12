defmodule Tymeslot.Bookings.AttendeeTextsLifecycleTest do
  @moduledoc """
  A booking made in one of the organiser's translation languages, after the
  confirmation (`Tymeslot.Bookings.AttendeeTextsEmailsTest`): every later
  email to the attendee keeps reading their copy of the booking's texts. A
  reminder, a cancellation, an approval request and its outcome, and the
  organiser's request to pick a new time, and a reschedule to another venue,
  which moves the attendee's copy of the location with the original.
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
  alias Tymeslot.Bookings.{Cancel, Create, Reschedule, RescheduleRequest}
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

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

    user = insert(:user, email: @organizer, name: "Olivia Host")

    profile =
      insert(:profile,
        user: user,
        timezone: "America/New_York",
        content_locale: "en",
        translation_locales: ["de"]
      )

    _schedule = open_schedule_for(profile)

    berlin =
      insert(:venue,
        user: user,
        name: "Berlin office",
        description: "Friedrichstrasse 1",
        translations: venue_translations("Berlin office", "Büro Berlin")
      )

    munich =
      insert(:venue,
        user: user,
        name: "Munich office",
        description: "Marienplatz 8",
        translations: venue_translations("Munich office", "Büro München")
      )

    offices = in_person_location([berlin, munich], id: "loc-offices", label: "In person")

    %{user: user, berlin: berlin, munich: munich, offices: offices}
  end

  defp venue_translations(name, text),
    do: %{"de" => %{"name" => %{"text" => text, "source" => :erlang.phash2(name)}}}

  defp meeting_type(ctx, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: ctx.user,
          name: "Intro call",
          duration_minutes: 30,
          locations: [ctx.offices],
          translations: %{
            "de" => %{
              "name" => %{"text" => "Erstgespräch", "source" => :erlang.phash2("Intro call")}
            }
          }
        ],
        attrs
      )
    )
  end

  defp book(ctx, meeting_type, venue) do
    assert {:ok, meeting} =
             Create.execute(
               %{
                 date: Date.add(Date.utc_today(), 1),
                 time: "14:00",
                 duration: "30min",
                 user_timezone: "America/New_York",
                 organizer_user_id: ctx.user.id,
                 meeting_type_id: meeting_type.id,
                 attendee_locale: "de",
                 location_option_id: "loc-offices",
                 location_venue_id: to_string(venue.id)
               },
               %{"name" => "Jana Gast", "email" => @attendee, "message" => ""}
             )

    meeting
  end

  # Runs the email jobs enqueued so far, and returns the emails delivered
  # since the last call, by recipient.
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

  test "the attendee's copy names the translated venue", ctx do
    meeting = book(ctx, meeting_type(ctx), ctx.berlin)

    assert meeting.location == "Berlin office (Friedrichstrasse 1)"
    assert meeting.attendee_texts["de"]["location"] == "Büro Berlin (Friedrichstrasse 1)"

    emails = delivered()
    assert only(emails, @attendee).html_body =~ "Büro Berlin"
    assert only(emails, @organizer).html_body =~ "Berlin office"
    refute only(emails, @organizer).html_body =~ "Büro Berlin"
  end

  test "a reschedule to another venue moves the attendee's copy of the location", ctx do
    meeting = book(ctx, meeting_type(ctx), ctx.berlin)
    _confirmations = delivered()

    assert {:ok, _updated} =
             Reschedule.execute(
               meeting.uid,
               %{
                 date: Date.to_string(Date.add(Date.utc_today(), 2)),
                 time: "2:00 PM",
                 duration: "30min",
                 user_timezone: "America/New_York",
                 location_option_id: "loc-offices",
                 location_venue_id: to_string(ctx.munich.id)
               },
               ctx.user.id
             )

    stored = Repo.get!(MeetingSchema, meeting.id)
    assert stored.location == "Munich office (Marienplatz 8)"

    assert %{"de" => %{"location" => "Büro München (Marienplatz 8)"}} = stored.attendee_texts

    emails = delivered()
    attendee = only(emails, @attendee)
    assert attendee.html_body =~ "Büro München"
    refute attendee.html_body =~ "Büro Berlin"

    assert ics = Enum.find(attendee.attachments, &(&1.content_type =~ "text/calendar"))
    assert ics.data =~ "Büro München"

    assert only(emails, @organizer).html_body =~ "Munich office"
  end

  test "a reschedule to a venue with nothing translated drops the copy", ctx do
    plain = insert(:venue, user: ctx.user, name: "Studio", description: "Hafen 3")
    offices = in_person_location([ctx.berlin, plain], id: "loc-offices", label: "In person")
    meeting_type = meeting_type(%{ctx | offices: offices}, translations: %{})

    meeting = book(ctx, meeting_type, ctx.berlin)
    assert meeting.attendee_texts["de"]["location"] == "Büro Berlin (Friedrichstrasse 1)"

    assert {:ok, _updated} =
             Reschedule.execute(
               meeting.uid,
               %{
                 date: Date.to_string(Date.add(Date.utc_today(), 2)),
                 time: "2:00 PM",
                 duration: "30min",
                 user_timezone: "America/New_York",
                 location_option_id: "loc-offices",
                 location_venue_id: to_string(plain.id)
               },
               ctx.user.id
             )

    assert Repo.get!(MeetingSchema, meeting.id).attendee_texts == nil
  end

  defp reschedule_to(ctx, meeting, venue) do
    assert {:ok, _updated} =
             Reschedule.execute(
               meeting.uid,
               %{
                 date: Date.to_string(Date.add(Date.utc_today(), 2)),
                 time: "2:00 PM",
                 duration: "30min",
                 user_timezone: "America/New_York",
                 location_option_id: "loc-offices",
                 location_venue_id: to_string(venue.id)
               },
               ctx.user.id
             )

    Repo.get!(MeetingSchema, meeting.id)
  end

  test "a reschedule keeps the rest of the attendee's copy as they booked it", ctx do
    meeting_type = meeting_type(ctx)
    meeting = book(ctx, meeting_type, ctx.berlin)

    # The organiser renames the type, and its translation, after the booking.
    meeting_type
    |> Changeset.change(
      name: "Discovery call",
      translations: %{
        "de" => %{
          "name" => %{"text" => "Kennenlernen", "source" => :erlang.phash2("Discovery call")}
        }
      }
    )
    |> Repo.update!()

    stored = reschedule_to(ctx, meeting, ctx.munich)

    # The booking's original is unchanged, and so is the attendee's copy of it.
    assert stored.meeting_type == "Intro call"

    assert %{
             "de" => %{
               "meeting_type" => "Erstgespräch",
               "location" => "Büro München (Marienplatz 8)"
             }
           } = stored.attendee_texts
  end

  test "a reschedule keeps the copy of a language the organiser no longer translates into",
       ctx do
    meeting = book(ctx, meeting_type(ctx), ctx.berlin)
    _confirmations = delivered()

    ProfileSchema
    |> Repo.get_by!(user_id: ctx.user.id)
    |> Changeset.change(translation_locales: [])
    |> Repo.update!()

    stored = reschedule_to(ctx, meeting, ctx.munich)

    # The new venue is not translated any more; what the attendee booked with is.
    assert %{"de" => %{"meeting_type" => "Erstgespräch", "location" => location}} =
             stored.attendee_texts

    assert location == stored.location

    attendee = only(delivered(), @attendee)
    assert attendee.html_body =~ "Erstgespräch"
    assert attendee.html_body =~ "Munich office"
  end

  test "a reschedule stores no copy where the booking had none and the location is not translated",
       ctx do
    plain = insert(:venue, user: ctx.user, name: "Studio", description: "Hafen 3")
    offices = in_person_location([plain, ctx.munich], id: "loc-offices", label: "In person")
    meeting_type = meeting_type(%{ctx | offices: offices}, translations: %{})

    meeting = book(ctx, meeting_type, plain)
    assert meeting.attendee_texts == nil

    # Translated since the booking, but not what the attendee booked with.
    meeting_type
    |> Changeset.change(
      translations: %{
        "de" => %{"name" => %{"text" => "Erstgespräch", "source" => :erlang.phash2("Intro call")}}
      }
    )
    |> Repo.update!()

    plain_again = insert(:venue, user: ctx.user, name: "Loft", description: "Kai 1")
    offices = in_person_location([plain, plain_again], id: "loc-offices", label: "In person")

    meeting_type
    |> Changeset.change(locations: [offices])
    |> Repo.update!()

    assert reschedule_to(ctx, meeting, plain_again).attendee_texts == nil
  end

  test "a reschedule onto a translated venue gives a booking without a copy its location alone",
       ctx do
    plain = insert(:venue, user: ctx.user, name: "Studio", description: "Hafen 3")
    offices = in_person_location([plain, ctx.munich], id: "loc-offices", label: "In person")
    meeting_type = meeting_type(%{ctx | offices: offices}, translations: %{})

    meeting = book(ctx, meeting_type, plain)
    assert meeting.attendee_texts == nil
    _confirmations = delivered()

    stored = reschedule_to(ctx, meeting, ctx.munich)
    assert stored.attendee_texts == %{"de" => %{"location" => "Büro München (Marienplatz 8)"}}

    # Every other text reads as the booking's own.
    attendee = only(delivered(), @attendee)
    assert attendee.html_body =~ "Büro München"
    assert attendee.html_body =~ "Intro call"
  end

  test "the reminder reads the attendee's copy", ctx do
    meeting = book(ctx, meeting_type(ctx), ctx.berlin)
    _confirmations = delivered()

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_reminder_emails",
               "meeting_id" => meeting.id,
               "reminder_value" => 30,
               "reminder_unit" => "minutes"
             })

    attendee = only(collect([]), @attendee)
    assert attendee.html_body =~ "Erstgespräch"
    assert attendee.html_body =~ "Büro Berlin"
    refute attendee.html_body =~ "Intro call"
  end

  test "the cancellation reads the attendee's copy", ctx do
    meeting = book(ctx, meeting_type(ctx), ctx.berlin)
    _confirmations = delivered()

    assert {:ok, _cancelled} = Cancel.execute(Repo.get!(MeetingSchema, meeting.id))

    attendee = only(delivered(), @attendee)
    assert attendee.html_body =~ "Erstgespräch"
    refute attendee.html_body =~ "Intro call"
  end

  test "the organiser's request for a new time reads the attendee's copy", ctx do
    meeting = book(ctx, meeting_type(ctx), ctx.berlin)
    _confirmations = delivered()

    assert :ok = RescheduleRequest.send_reschedule_request(Repo.get!(MeetingSchema, meeting.id))

    attendee = only(delivered(), @attendee)
    assert attendee.html_body =~ "Erstgespräch"
    assert attendee.html_body =~ "Büro Berlin"
    refute attendee.html_body =~ "Intro call"
  end

  test "an approval request and its decline read the attendee's copy, the host their own",
       ctx do
    meeting = book(ctx, meeting_type(ctx, requires_approval: true), ctx.berlin)
    assert meeting.status == :awaiting_approval

    requested = delivered()
    attendee = only(requested, @attendee)
    assert attendee.html_body =~ "Erstgespräch"
    assert attendee.subject =~ "Erstgespräch"
    assert attendee.html_body =~ "Büro Berlin"
    refute attendee.html_body =~ "Intro call"

    host = only(requested, @organizer)
    assert host.html_body =~ "Intro call"
    refute host.html_body =~ "Erstgespräch"

    assert {:ok, _declined} = Approval.decline(Repo.get!(MeetingSchema, meeting.id))

    outcome = only(delivered(), @attendee)
    assert outcome.html_body =~ "Erstgespräch"
    assert outcome.html_body =~ "Büro Berlin"
    refute outcome.html_body =~ "Intro call"
  end
end
