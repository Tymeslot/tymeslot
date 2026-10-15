defmodule Tymeslot.Bookings.GuestInvitePrivacyIntegrationTest do
  @moduledoc """
  A guest's calendar file carries nothing the booker told only the host.

  Every guest email attaches an `.ics`, and the guest's copy used to be
  rendered from the booker's full payload: their address as the ATTENDEE, and
  their message and booking-form answers in the DESCRIPTION. The email bodies
  never showed these, so only the attachment leaked them.

  This runs the booking's whole life against the real email service
  (confirmation job, reschedule, cancellation) and decodes each calendar file
  a guest receives, beside the booker's own copy of the same email, which
  must still carry everything. The guest's copy must stay the same event: an
  entry with a different UID or ORGANIZER would not be updated or cancelled
  by the files that follow it.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :emails
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  @booker_email "bea.booker@example.com"
  @booker_name "Bea Booker"
  @guest_email "gus.guest@example.com"
  @message "Please keep this between us: the merger closes Friday."
  @phone "+44 7700 900123"
  @company "Quietly Acquired Ltd"
  @question "Annual budget"
  @answer "Four hundred thousand"

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.stub_no_calendar_events()

    # The real service, so the templates and their calendar files render.
    original_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    # Delivery runs inside the circuit breaker's process; this collects the
    # rendered emails here instead. Safe because the module is `async: false`.
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, original_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    %{user: user} = create_always_bookable_profile(timezone: "Europe/Berlin")
    start_time = at_ten(3)

    meeting =
      insert(:meeting,
        uid: UUID.generate(),
        organizer_user_id: user.id,
        organizer_email: "organiser-#{user.id}@example.com",
        organizer_name: "Olive Organiser",
        attendee_name: @booker_name,
        attendee_email: @booker_email,
        attendee_message: @message,
        attendee_phone: @phone,
        attendee_company: @company,
        meeting_type: "Consultation",
        title: "Consultation with #{@booker_name}",
        custom_fields_snapshot: [%{"id" => "budget", "label" => @question, "type" => "text"}],
        custom_field_answers: %{"budget" => @answer},
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute),
        duration: 30,
        status: "confirmed",
        # Stamped when a booking is announced; only an announced booking's
        # guests are told it was cancelled.
        first_announced_at: DateTime.utc_now(:second),
        organizer_email_sent: false,
        attendee_email_sent: false
      )

    {:ok, [_guest]} = Guests.create_for_meeting(meeting.id, [@guest_email])

    %{user: user, meeting: meeting}
  end

  test "the guest's calendar files leave out the booker's private details, all the booking long",
       %{user: user, meeting: meeting} do
    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_confirmation_emails",
               "meeting_id" => meeting.id
             })

    confirmation = calendar_files()

    assert {:ok, _rescheduled} =
             Reschedule.execute(meeting.uid, reschedule_params(at_ten(5)), %{}, user.id)

    reschedule = calendar_files()

    assert {:ok, _cancelled} = Cancel.execute(Repo.get!(MeetingSchema, meeting.id))

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_cancellation_emails",
               "meeting_id" => meeting.id
             })

    cancellation = calendar_files()

    for {stage, files} <- [
          confirmation: confirmation,
          reschedule: reschedule,
          cancellation: cancellation
        ] do
      booker_ics = Map.fetch!(files, @booker_email)
      guest_ics = Map.fetch!(files, @guest_email)

      # The booker's own copy is untouched, which also proves the private
      # details were there to leak.
      assert booker_ics =~ "mailto:#{@booker_email}", "#{stage}: booker copy lost the ATTENDEE"
      assert booker_ics =~ "merger closes Friday", "#{stage}: booker copy lost the message"
      assert booker_ics =~ @answer, "#{stage}: booker copy lost the answers"

      for private <- [@booker_email, "merger closes Friday", @phone, @company, @question, @answer] do
        refute guest_ics =~ private, "#{stage}: guest copy carries #{inspect(private)}"
      end

      # Who arranged the meeting is not private: the title names them.
      assert guest_ics =~ @booker_name, "#{stage}: guest copy lost the booker's name"

      # The same event, so later files update and cancel the guest's entry.
      assert property(guest_ics, "UID") == property(booker_ics, "UID")
      assert property(guest_ics, "ORGANIZER") == property(booker_ics, "ORGANIZER")
    end
  end

  # The calendar file of each email delivered since the last call, unfolded
  # and keyed by recipient address. Emails without one (the organiser's
  # confirmation and reschedule notice) are left out.
  defp calendar_files(acc \\ %{}) do
    receive do
      {:email, email} ->
        acc =
          case Enum.find(email.attachments, &(&1.content_type =~ "text/calendar")) do
            nil -> acc
            ics -> Map.put(acc, email.to |> hd() |> elem(1), unfold(ics.data))
          end

        calendar_files(acc)
    after
      0 -> acc
    end
  end

  # RFC 5545 folds long lines; join them back so a value split across a fold
  # still matches.
  defp unfold(ics), do: String.replace(ics, "\r\n ", "")

  defp property(ics, name) do
    [line] = Regex.run(~r/^#{name}[;:].*$/m, ics)
    line
  end

  # A pinned time of day, so the open schedule's grid always offers it.
  defp at_ten(days_ahead) do
    future = DateTime.add(DateTime.utc_now(), days_ahead, :day)
    %{future | hour: 10, minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp reschedule_params(%DateTime{} = target_utc) do
    in_berlin = DateTime.shift_zone!(target_utc, "Europe/Berlin")

    %{
      date: Date.to_iso8601(DateTime.to_date(in_berlin)),
      time: Calendar.strftime(in_berlin, "%H:%M"),
      duration: "30min",
      user_timezone: "Europe/Berlin"
    }
  end
end
