defmodule Tymeslot.Polls.ConfirmGuestLocalesTest do
  @moduledoc """
  Each participant of a confirmed poll hears about the meeting in their own
  language and timezone, not the primary participant's: on the confirmation,
  the reminders, and the notices when the host moves or cancels it.
  """
  # Not async: the real email service is swapped in for the mock, and Swoosh
  # delivers to the test process through the shared-process setting.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Bookings.HostMove
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  @ada "ada@example.com"
  @ben "ben@example.com"

  setup do
    TestMocks.resolve_booking_calendars()

    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    user = insert(:user)
    insert(:profile, user: user, timezone: "Etc/UTC")
    poll = insert(:poll, user: user, status: :open, timezone: "Etc/UTC", meeting_type_id: nil)

    # 15:00 UTC, five days out: 16:00 in London or 15:00 in winter, and
    # 10:00 or 11:00 in New York, so the two zones never show the same hour.
    start_time =
      Date.utc_today()
      |> Date.add(5)
      |> DateTime.new!(~T[15:00:00], "Etc/UTC")

    slot =
      insert(:poll_time_slot,
        poll: poll,
        start_time: start_time,
        end_time: DateTime.add(start_time, 1, :hour)
      )

    ada =
      insert(:poll_participant,
        poll: poll,
        name: "Ada Lind",
        email: @ada,
        locale: "en",
        timezone: "Europe/London"
      )

    ben =
      insert(:poll_participant,
        poll: poll,
        name: "Ben Ito",
        email: @ben,
        locale: "de",
        timezone: "America/New_York"
      )

    # Ada voted for the slot and Ben did not, so Ada is the primary and the
    # meeting's attendee language and timezone are hers.
    insert(:poll_vote, participant: ada, time_slot: slot, response: :yes)
    insert(:poll_vote, participant: ben, time_slot: slot, response: :no)

    {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)

    %{user: user, meeting: meeting}
  end

  test "each guest keeps their own language and timezone", %{meeting: meeting} do
    assert meeting.attendee_locale == "en"
    assert meeting.attendee_timezone == "Europe/London"

    guests = meeting.id |> Guests.list_for_meeting() |> Map.new(&{&1.email, &1})

    assert {guests[@ada].locale, guests[@ada].timezone} == {"en", "Europe/London"}
    assert {guests[@ben].locale, guests[@ben].timezone} == {"de", "America/New_York"}
  end

  test "the confirmation reaches each guest in their own language and time", %{meeting: meeting} do
    send_confirmations(meeting)

    emails = guest_emails()

    assert emails[@ben].subject =~ "Sie sind eingeladen"
    assert emails[@ben].text_body =~ "Uhrzeit: #{local_time(meeting.start_time, :ben)}"
    assert emails[@ben].text_body =~ "(America/New_York)"
    refute emails[@ben].text_body =~ "Europe/London"

    assert emails[@ada].subject =~ "You're invited"
    assert emails[@ada].text_body =~ "Time: #{local_time(meeting.start_time, :ada)}"
    assert emails[@ada].text_body =~ "(Europe/London)"
  end

  test "a reminder reaches each guest in their own language and time", %{meeting: meeting} do
    send_confirmations(meeting)
    _confirmations = guest_emails()

    assert :ok =
             EmailHandlers.execute_email_action("send_reminder_emails", %{
               "meeting_id" => meeting.id,
               "reminder_value" => 1,
               "reminder_unit" => "days"
             })

    emails = guest_emails()

    assert emails[@ben].text_body =~ "Hallo Ben Ito"
    assert emails[@ben].text_body =~ "Uhrzeit: #{local_time(meeting.start_time, :ben)}"
    assert emails[@ben].text_body =~ "(America/New_York)"

    assert emails[@ada].text_body =~ "Hi Ada Lind"
    assert emails[@ada].text_body =~ "Time: #{local_time(meeting.start_time, :ada)}"
  end

  test "the host's move reaches each guest in their own language and time",
       %{user: user, meeting: meeting} do
    send_confirmations(meeting)
    _confirmations = guest_emails()

    new_start = DateTime.add(meeting.start_time, 1, :day)
    assert {:ok, _moved} = HostMove.move(meeting.uid, new_start, user.id)
    run_email_job("send_reschedule_emails")

    emails = guest_emails()

    assert emails[@ben].text_body =~ "Hallo Ben Ito"
    assert emails[@ben].text_body =~ "Uhrzeit: #{local_time(new_start, :ben)}"
    assert emails[@ben].text_body =~ "(America/New_York)"
    refute emails[@ben].text_body =~ "Europe/London"

    assert emails[@ada].text_body =~ "Hi Ada Lind"
    assert emails[@ada].text_body =~ "Time: #{local_time(new_start, :ada)}"
  end

  test "the host's cancellation reaches each guest in their own language",
       %{user: user, meeting: meeting} do
    send_confirmations(meeting)
    _confirmations = guest_emails()

    {:ok, meeting} = Meetings.get_meeting_for_organizer(meeting.id, user.id)
    assert {:ok, _cancelled} = Meetings.cancel_meeting_with_refund(meeting, user.id, :none)
    run_email_job("send_cancellation_emails")

    emails = guest_emails()

    assert emails[@ben].text_body =~ "Hallo Ben Ito"
    assert emails[@ben].text_body =~ "(America/New_York)"
    assert emails[@ada].text_body =~ "Hi Ada Lind"
    assert emails[@ada].text_body =~ "(Europe/London)"
  end

  describe "a guest added on an ordinary booking" do
    test "hears in the attendee's language and timezone, having none of their own" do
      start_time = DateTime.add(DateTime.utc_now(:second), 5, :day)

      meeting =
        insert(:meeting,
          status: "confirmed",
          attendee_locale: "de",
          attendee_timezone: "America/New_York",
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour)
        )

      {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["plus-one@example.com"])
      assert {guest.locale, guest.timezone} == {nil, nil}

      send_confirmations(meeting)

      assert_received {:email, %Swoosh.Email{to: [{_name, "plus-one@example.com"}]} = email}
      assert email.subject =~ "Sie sind eingeladen"
      assert email.text_body =~ "Uhrzeit: #{local_time(start_time, :ben)}"
      assert email.text_body =~ "(America/New_York)"
    end
  end

  defp send_confirmations(meeting) do
    EmailHandlers.execute_email_action("send_confirmation_emails", %{"meeting_id" => meeting.id})
  end

  # Runs the email job the domain enqueued, as the queue would.
  defp run_email_job(action) do
    job =
      [worker: EmailWorker]
      |> all_enqueued()
      |> Enum.find(&(&1.args["action"] == action))

    assert job, "expected a #{action} job to be enqueued"
    assert :ok = perform_job(EmailWorker, job.args)
  end

  # The time as each guest's email prints it: Ben's in New York on the German
  # 24-hour clock, Ada's in London on the English 12-hour one.
  defp local_time(at, :ben),
    do: at |> DateTime.shift_zone!("America/New_York") |> Calendar.strftime("%H:%M")

  defp local_time(at, :ada),
    do: at |> DateTime.shift_zone!("Europe/London") |> Calendar.strftime("%I:%M %p")

  # Every guest email delivered so far, by address; the host's are skipped.
  defp guest_emails, do: collect(%{})

  defp collect(acc) do
    receive do
      {:email, %Swoosh.Email{to: [{_name, address}]} = email} when address in [@ada, @ben] ->
        collect(Map.put(acc, address, email))

      {:email, _other} ->
        collect(acc)
    after
      0 -> acc
    end
  end
end
