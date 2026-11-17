defmodule Tymeslot.Bookings.AttendeeTextsGroupTest do
  @moduledoc """
  The attendees' copies of a shared slot's texts
  (`Tymeslot.ContentTranslations.AttendeeTexts`): on a group meeting or a
  planned session every participant reads the same slot, so the slot holds
  one copy per language its participants booked in, and each participant
  reads their own while the organiser reads the originals.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :i18n
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Bookings.{Create, RescheduleLocation, RescheduleRequest, RescheduleSeat}
  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.AttendeeTexts
  alias Tymeslot.CustomFields
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.TestMocks

  @organizer "organizer@example.com"
  @jana "jana@example.com"
  @lea "lea@example.com"
  @marco "marco@example.com"

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

    :ok
  end

  defp translations(pairs) do
    Map.new(pairs, fn {locale, original, text} ->
      {locale, %{"name" => %{"text" => text, "source" => :erlang.phash2(original)}}}
    end)
  end

  defp organiser(content_locale, translation_locales) do
    user = insert(:user, email: @organizer, name: "Olivia Host")

    profile =
      insert(:profile,
        user: user,
        timezone: "America/New_York",
        content_locale: content_locale,
        translation_locales: translation_locales
      )

    {user, profile}
  end

  describe "a group meeting" do
    setup do
      {user, profile} = organiser("en", ["de", "fr", "it"])
      _schedule = open_schedule_for(profile)

      berlin =
        insert(:venue,
          user: user,
          name: "Berlin office",
          description: "Friedrichstrasse 1",
          translations:
            translations([
              {"de", "Berlin office", "Büro Berlin"},
              {"fr", "Berlin office", "Bureau de Berlin"},
              {"it", "Berlin office", "Ufficio di Berlino"}
            ])
        )

      munich =
        insert(:venue,
          user: user,
          name: "Munich office",
          description: "Marienplatz 8",
          translations:
            translations([
              {"de", "Munich office", "Büro München"},
              {"fr", "Munich office", "Bureau de Munich"}
            ])
        )

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Intro call",
          duration_minutes: 30,
          max_participants: 3,
          locations: [in_person_location([berlin], id: "loc-berlin")],
          translations: translations([{"de", "Intro call", "Erstgespräch"}])
        )

      %{user: user, berlin: berlin, munich: munich, meeting_type: meeting_type}
    end

    test "each participant reads their own language's copy, the organiser the originals",
         ctx do
      _jana = book_seat!(ctx, @jana, "de")
      _confirmation = delivered()
      meeting = book_seat!(ctx, @lea, "fr")

      assert %{
               "de" => %{
                 "meeting_type" => "Erstgespräch",
                 "location" => "Büro Berlin (Friedrichstrasse 1)"
               },
               "fr" => %{
                 "meeting_type" => "Intro call",
                 "location" => "Bureau de Berlin (Friedrichstrasse 1)"
               }
             } = Repo.get!(MeetingSchema, meeting.id).attendee_texts

      lea = delivered()
      lea_body = only(lea, @lea).html_body
      assert lea_body =~ "Bureau de Berlin"
      refute lea_body =~ "Büro Berlin"
      refute lea_body =~ "Erstgespräch"

      organizer_body = only(lea, @organizer).html_body
      assert organizer_body =~ "Intro call"
      refute organizer_body =~ "Bureau de Berlin"
      refute organizer_body =~ "Erstgespräch"

      # Jana's copy survives Léa's seat: her next email still reads German.
      assert :ok = RescheduleRequest.send_reschedule_request(Repo.get!(MeetingSchema, meeting.id))
      requests = delivered()
      jana_body = only(requests, @jana).html_body
      assert jana_body =~ "Büro Berlin"
      assert jana_body =~ "Erstgespräch"
      refute jana_body =~ "Bureau de Berlin"

      assert only(requests, @lea).html_body =~ "Bureau de Berlin"
    end

    # A slot's title is the type's original name, not built from the
    # "<type> with <name>" template, so it is the name the participant reads:
    # in their calendar entry and in a subject that names the meeting.
    test "a participant's email subject and calendar entry name the type in their language",
         ctx do
      meeting = book_seat!(ctx, @jana, "de")
      assert meeting.title == "Intro call"

      confirmation = only(delivered(), @jana)

      assert [ics] =
               for(
                 %{content_type: "text/calendar", data: data} <- confirmation.attachments,
                 do: data
               )

      assert ics =~ "SUMMARY;LANGUAGE=de:Erstgespräch"
      refute ics =~ "Intro call"

      assert :ok = RescheduleRequest.send_reschedule_request(Repo.get!(MeetingSchema, meeting.id))
      request_subject = only(delivered(), @jana).subject
      assert request_subject =~ "Erstgespräch"
      refute request_subject =~ "Intro call"
    end

    test "a second booker in a language the slot already holds leaves its copy alone", ctx do
      meeting = book_seat!(ctx, @jana, "de")

      # The organiser rewords the German name after the slot was created; the
      # slot's copy keeps reading as the slot did when it was made.
      ctx.meeting_type
      |> Changeset.change(translations: translations([{"de", "Intro call", "Kennenlernen"}]))
      |> Repo.update!()

      _joined = book_seat!(ctx, @lea, "de")

      texts = Repo.get!(MeetingSchema, meeting.id).attendee_texts
      assert Map.keys(texts) == ["de"]
      assert texts["de"]["meeting_type"] == "Erstgespräch"
    end

    test "a joiner's copy leaves out a text the type has changed since the slot was made",
         ctx do
      meeting = book_seat!(ctx, @lea, "fr")

      ctx.meeting_type
      |> Changeset.change(
        name: "Discovery call",
        translations: translations([{"de", "Discovery call", "Kennenlernen"}])
      )
      |> Repo.update!()

      _joined = book_seat!(ctx, @jana, "de")

      slot = Repo.get!(MeetingSchema, meeting.id)
      assert slot.meeting_type == "Intro call"
      refute Map.has_key?(slot.attendee_texts["de"], "meeting_type")
      assert slot.attendee_texts["de"]["location"] == "Büro Berlin (Friedrichstrasse 1)"
      assert AttendeeTexts.text(slot, :meeting_type, "de") == "Intro call"
    end

    test "a booker in a language that is not a translation language adds no copy", ctx do
      meeting = book_seat!(ctx, @jana, "de")
      _joined = book_seat!(ctx, @lea, "es")

      assert Map.keys(Repo.get!(MeetingSchema, meeting.id).attendee_texts) == ["de"]
    end

    test "a location change rebuilds every language's copy, dropping one left untranslated",
         ctx do
      # Jana books first, so the slot's own `attendee_locale` is hers.
      _jana = book_seat!(ctx, @jana, "de")
      _lea = book_seat!(ctx, @lea, "fr")
      meeting = book_seat!(ctx, @marco, "it")
      meeting = Repo.get!(MeetingSchema, meeting.id)
      assert Map.keys(meeting.attendee_texts) == ["de", "fr", "it"]

      # A group type offers one venue; the move goes through the choice a
      # type offering both would give, which is all `attributes/3` reads.
      offices = in_person_location([ctx.berlin, ctx.munich], id: "loc-offices")
      meeting_type = %{ctx.meeting_type | locations: [offices]}

      changes =
        RescheduleLocation.attributes(meeting, meeting_type, %{
          location_option_id: "loc-offices",
          location_venue_id: to_string(ctx.munich.id)
        })

      assert changes.location == "Munich office (Marienplatz 8)"

      # Italian has the name untranslated and no Munich venue, so its copy
      # now reads as the originals and goes.
      assert changes.attendee_texts == %{
               "de" =>
                 Map.merge(meeting.attendee_texts["de"], %{
                   "location" => "Büro München (Marienplatz 8)"
                 }),
               "fr" =>
                 Map.merge(meeting.attendee_texts["fr"], %{
                   "location" => "Bureau de Munich (Marienplatz 8)"
                 })
             }
    end
  end

  describe "a seat move onto a slot others have booked" do
    setup do
      {user, profile} = organiser("en", ["de", "fr"])
      _schedule = open_schedule_for(profile)

      venue =
        insert(:venue,
          user: user,
          name: "Berlin office",
          description: "Friedrichstrasse 1",
          translations: translations([{"fr", "Berlin office", "Bureau de Berlin"}])
        )

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Intro call",
          duration_minutes: 30,
          max_participants: 3,
          locations: [in_person_location([venue])],
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

      %{user: user, meeting_type: meeting_type}
    end

    defp book_with_questions!(ctx, email, locale, days_ahead) do
      snapshot =
        ctx.meeting_type
        |> ContentTranslations.localise(locale)
        |> CustomFields.snapshot_for()

      assert {:ok, meeting} =
               Create.execute(
                 %{
                   date: Date.add(Date.utc_today(), days_ahead),
                   time: "14:00",
                   duration: "30min",
                   user_timezone: "America/New_York",
                   organizer_user_id: ctx.user.id,
                   meeting_type_id: ctx.meeting_type.id,
                   attendee_locale: locale,
                   custom_fields_snapshot: snapshot,
                   custom_field_answers: %{"q-company" => "Acme"}
                 },
                 %{"name" => "Booker #{email}", "email" => email, "message" => ""}
               )

      meeting
    end

    test "the mover's copy carries the slot's questions in their language", ctx do
      old_slot = book_with_questions!(ctx, @jana, "de", 1)
      target = book_with_questions!(ctx, @lea, "fr", 2)
      assert Map.keys(target.attendee_texts) == ["fr"]

      jana =
        Enum.find(ParticipantQueries.list_live_for_meeting(old_slot.id), &(&1.email == @jana))

      assert {:ok, %{meeting: moved_to}} =
               RescheduleSeat.execute(
                 jana.management_token,
                 %{
                   date: Date.to_iso8601(Date.add(Date.utc_today(), 2)),
                   time: "14:00",
                   duration: "30min",
                   user_timezone: "America/New_York"
                 },
                 ctx.user.id
               )

      assert moved_to.id == target.id
      slot = Repo.get!(MeetingSchema, target.id)
      assert [%{"label" => "Company"}] = slot.custom_fields_snapshot

      assert %{
               "meeting_type" => "Erstgespräch",
               "custom_fields_snapshot" => [%{"label" => "Firma"}]
             } = slot.attendee_texts["de"]

      assert [%{"label" => "Firma"}] = AttendeeTexts.text(slot, :custom_fields_snapshot, "de")
    end
  end

  describe "a planned session" do
    setup do
      # The booking default (`en`) is a translation language, so a session
      # built for no one would read as booked in it.
      {user, _profile} = organiser("de", ["en", "fr"])
      venue = insert(:venue, user: user, name: "Saal", description: "Hafen 3")

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Einführung",
          duration_minutes: 90,
          max_participants: 3,
          fixed_dates: true,
          locations: [in_person_location([venue])],
          translations:
            translations([
              {"en", "Einführung", "Introduction"},
              {"fr", "Einführung", "Initiation"}
            ])
        )

      starts_at = Date.utc_today() |> Date.add(5) |> DateTime.new!(~T[18:00:00], "Etc/UTC")
      {:ok, session} = PlannedSessions.add(meeting_type, user.id, starts_at)

      %{user: user, meeting_type: meeting_type, session: session, starts_at: starts_at}
    end

    test "holds no copy until a participant books, then theirs", ctx do
      assert Repo.get!(MeetingSchema, ctx.session.id).attendee_texts == nil

      assert {:ok, _meeting} =
               Create.execute(
                 %{
                   date: DateTime.to_date(ctx.starts_at),
                   time: "18:00",
                   duration: "90min",
                   user_timezone: "Etc/UTC",
                   organizer_user_id: ctx.user.id,
                   meeting_type_id: ctx.meeting_type.id,
                   attendee_locale: "fr"
                 },
                 %{"name" => "Léa", "email" => @lea}
               )

      assert %{"fr" => %{"meeting_type" => "Initiation"}} =
               texts = Repo.get!(MeetingSchema, ctx.session.id).attendee_texts

      assert Map.keys(texts) == ["fr"]
    end
  end

  defp book_seat!(ctx, email, locale) do
    assert {:ok, meeting} =
             Create.execute(
               %{
                 date: Date.add(Date.utc_today(), 1),
                 time: "14:00",
                 duration: "30min",
                 user_timezone: "America/New_York",
                 organizer_user_id: ctx.user.id,
                 meeting_type_id: ctx.meeting_type.id,
                 attendee_locale: locale
               },
               %{"name" => "Booker #{email}", "email" => email, "message" => ""}
             )

    meeting
  end

  # Runs the email jobs enqueued so far, and returns the emails delivered
  # since the last call, by recipient.
  defp delivered do
    Oban.drain_queue(queue: :emails, with_recursion: true)
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
end
