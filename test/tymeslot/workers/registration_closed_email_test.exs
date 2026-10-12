defmodule Tymeslot.Workers.RegistrationClosedEmailTest do
  @moduledoc """
  The organiser's participant list for a planned session: scheduled for the
  moment registration closes when the session is planned, and, when it
  runs, sent with who signed up (their guests and answers included, and as
  a CSV attachment), or not at all for a session that has been cancelled.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :emails

  import Mox
  import Swoosh.TestAssertions
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Swoosh.Attachment
  alias Tymeslot.Emails.Templates.RegistrationClosed
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!
  # Delivery runs inside the CircuitBreaker GenServer; global mode routes the
  # test adapter's messages to this process. It requires `async: false`.
  setup :set_swoosh_global

  setup do
    TestMocks.setup_calendar_mocks()
    AvailabilityCache.clear_all()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "host@example.com", name: "Host")
    insert(:profile, user: user, timezone: "Etc/UTC")
    venue = insert(:venue, user: user, name: "Main Hall")

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Introduction to X",
        duration_minutes: 90,
        is_active: true,
        max_participants: 10,
        fixed_dates: true,
        locations: [in_person_location([venue])]
      )

    starts_at = Date.utc_today() |> Date.add(10) |> DateTime.new!(~T[18:00:00], "Etc/UTC")
    closes_at = DateTime.add(starts_at, -2, :day)

    {:ok, session} =
      PlannedSessions.add(meeting_type, starts_at, registration_closes_at: closes_at)

    %{meeting_type: meeting_type, session: session, starts_at: starts_at, closes_at: closes_at}
  end

  defp run_list_job(session) do
    perform_job(EmailWorker, %{"action" => "send_registration_closed", "meeting_id" => session.id})
  end

  # The job runs in a task of its own, so a frozen clock would not reach it:
  # registration is closed by moving the deadline into the past instead.
  defp after_close(ctx, fun) do
    ctx.session
    |> Changeset.change(registration_closes_at: DateTime.add(DateTime.utc_now(:second), -60))
    |> Repo.update!()

    fun.()
  end

  # The layout embeds the logo as an inline attachment of every email.
  defp csv_attachments(email),
    do: Enum.filter(email.attachments, &(&1.content_type == "text/csv"))

  describe "scheduling" do
    test "planning a session schedules the list for when registration closes", ctx do
      assert [job] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{"action" => "send_registration_closed", "meeting_id" => ctx.session.id}
               )

      assert DateTime.compare(job.scheduled_at, ctx.closes_at) == :eq
    end

    test "without a deadline, the list is due at the start", ctx do
      starts_at = DateTime.add(ctx.starts_at, 7, :day)
      {:ok, session} = PlannedSessions.add(ctx.meeting_type, starts_at)

      assert [job] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{"action" => "send_registration_closed", "meeting_id" => session.id}
               )

      assert DateTime.compare(job.scheduled_at, starts_at) == :eq
    end
  end

  describe "sending" do
    test "lists everyone who signed up, with their guests and answers", ctx do
      snapshot = [%{"id" => "diet", "label" => "Dietary needs", "type" => "text"}]

      ctx.session
      |> Changeset.change(custom_fields_snapshot: snapshot)
      |> Repo.update!()

      ada =
        insert(:participant,
          meeting: ctx.session,
          name: "Ada Lovelace",
          email: "ada@example.com",
          company: "Analytical Engines",
          custom_field_answers: %{"diet" => "Vegetarian"}
        )

      Repo.insert!(%GuestSchema{
        meeting_id: ctx.session.id,
        participant_id: ada.id,
        name: "Charles Babbage",
        email: "charles@example.com",
        invited_by: :booker
      })

      insert(:participant, meeting: ctx.session, name: "Grace Hopper", email: "grace@example.com")

      insert(:participant,
        meeting: ctx.session,
        name: "Gone Again",
        email: "gone@example.com",
        cancelled_at: DateTime.utc_now(:second)
      )

      assert :ok = after_close(ctx, fn -> run_list_job(ctx.session) end)

      assert_email_sent(fn email ->
        assert email.to == [{"Host", "host@example.com"}]
        assert email.subject =~ "Registration closed: Introduction to X"
        assert email.text_body =~ "2 people signed up for Introduction to X"
        assert email.text_body =~ "3 of 10 spots taken"
        assert email.text_body =~ "Ada Lovelace"
        assert email.text_body =~ "Analytical Engines"
        assert email.text_body =~ "Guests: Charles Babbage <charles@example.com>"
        assert email.text_body =~ "Dietary needs: Vegetarian"
        assert email.text_body =~ "Grace Hopper"
        refute email.text_body =~ "Gone Again"
        assert email.html_body =~ "Ada Lovelace"

        assert [%Attachment{data: csv}] = csv_attachments(email)
        assert [header, ada_row, grace_row] = csv |> String.trim() |> String.split("\r\n")
        assert header =~ ~s("Name","Email","Phone","Company","Guests","Message","Dietary needs")
        assert ada_row =~ ~s("Ada Lovelace","ada@example.com","","Analytical Engines")
        assert ada_row =~ ~s("Vegetarian")
        assert grace_row =~ ~s("Grace Hopper","grace@example.com")
        true
      end)
    end

    test "says so when nobody signed up, without an attachment", ctx do
      assert :ok = after_close(ctx, fn -> run_list_job(ctx.session) end)

      assert_email_sent(fn email ->
        assert email.text_body =~ "Nobody signed up for Introduction to X"
        assert csv_attachments(email) == []
        true
      end)
    end

    test "sends nothing for a cancelled session", ctx do
      ctx.session |> Changeset.change(status: "cancelled") |> Repo.update!()

      assert {:discard, _reason} = after_close(ctx, fn -> run_list_job(ctx.session) end)
      assert_no_email_sent()
    end

    test "waits while registration is still open", ctx do
      assert {:snooze, seconds} = run_list_job(ctx.session)
      assert seconds > 0
      assert_no_email_sent()
    end

    test "sends nothing for a meeting that is not a planned session", ctx do
      meeting = insert(:meeting, organizer_user_id: ctx.meeting_type.user_id)
      refute Repo.get!(MeetingSchema, meeting.id).planned

      assert {:discard, _reason} = run_list_job(meeting)
      assert_no_email_sent()
    end
  end

  test "the CSV keeps a spreadsheet from running a cell as a formula" do
    csv =
      RegistrationClosed.csv([
        %{
          name: "=HYPERLINK(\"http://evil\")",
          email: "a@example.com",
          phone: nil,
          company: nil,
          message: nil,
          guests: [],
          answers: []
        }
      ])

    assert csv =~ ~S|"'=HYPERLINK(""http://evil"")"|
  end
end
