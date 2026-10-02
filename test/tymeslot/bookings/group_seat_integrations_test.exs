defmodule Tymeslot.Bookings.GroupSeatIntegrationsTest do
  @moduledoc """
  Integration coverage for what webhooks, Telegram and Slack hear about a
  group meeting: every seat is a booking of its own. Booking, cancelling and
  moving a seat each reach the integrations as that seat's event, naming its
  participant, and a host cancelling the whole slot reaches them once per
  seat that was live. A solo booking's jobs and payload are unchanged.

  Drives the real booking flows, then performs the enqueued delivery jobs
  against the HTTP client mock and asserts on what was posted.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :webhooks
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.{Cancel, CancelSeat, Create, RescheduleSeat}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.TestMocks
  alias Tymeslot.Webhooks
  alias Tymeslot.Workers.{SlackWorker, TelegramWorker, WebhookWorker}

  @all_events ["meeting.created", "meeting.cancelled", "meeting.rescheduled"]

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
      slack_notifications_allowed: true,
      http_client_module: Tymeslot.HTTPClientMock,
      environment: :test
    )

    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")
    profile = insert(:profile, user: user, timezone: "America/New_York")
    open_schedule_for(profile)

    venue = insert(:venue, user: user, name: "Main Hall", description: "1 Market Square")

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Group Workshop",
        duration_minutes: 30,
        is_active: true,
        max_participants: 5,
        allow_guests: true,
        locations: [in_person_location([venue])]
      )

    webhook = insert(:webhook, user: user, events: @all_events)
    insert(:telegram_integration, user: user, events: @all_events)
    insert(:slack_integration, user: user, events: @all_events)

    params = %{
      date: Date.add(Date.utc_today(), 2),
      time: "14:00",
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    %{user: user, webhook: webhook, params: params}
  end

  defp book_seat!(params, name, email, guest_emails \\ []) do
    assert {:ok, meeting} =
             Create.execute(Map.put(params, :guest_emails, guest_emails), %{
               "name" => name,
               "email" => email
             })

    participant =
      meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Enum.find(&(&1.email == email))

    {meeting, participant}
  end

  defp jobs(worker, event_type) do
    worker
    |> then(&all_enqueued(worker: &1))
    |> Enum.filter(&(&1.args["event_type"] == event_type))
  end

  # Performs a delivery job and returns what it posted.
  defp posted_body!(worker, job) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :post, fn _url, body, _headers, _opts ->
      send(test_pid, {:posted, body})
      {:ok, %Req.Response{status: 200, body: ~s({"ok":true,"result":{},"ts":"1.2"})}}
    end)

    assert :ok = perform_job(worker, job.args)
    assert_received {:posted, body}
    body
  end

  defp webhook_meeting!(job) do
    WebhookWorker
    |> posted_body!(job)
    |> Jason.decode!()
    |> get_in(["data", "meeting"])
  end

  defp job_for(jobs, participant_id) do
    assert [job] = Enum.filter(jobs, &(&1.args["participant_id"] == participant_id))
    job
  end

  describe "a seat booked" do
    test "two seats booked seconds apart each reach the webhook as their own booking, with their own guests",
         %{params: params} do
      {meeting, first} =
        book_seat!(params, "First Booker", "first@example.com", ["g1@example.com"])

      {same_slot, second} =
        book_seat!(params, "Second Booker", "second@example.com", ["g2@example.com"])

      assert same_slot.id == meeting.id

      created = jobs(WebhookWorker, "meeting.created")
      assert length(created) == 2

      first_payload = webhook_meeting!(job_for(created, first.id))
      second_payload = webhook_meeting!(job_for(created, second.id))

      assert first_payload["attendee"]["name"] == "First Booker"
      assert first_payload["attendee"]["email"] == "first@example.com"
      assert Enum.map(first_payload["guests"], & &1["email"]) == ["g1@example.com"]

      assert first_payload["seat"] == %{
               "id" => first.id,
               "capacity" => 5,
               "seats_taken" => 2,
               "previous" => nil
             }

      assert second_payload["attendee"]["name"] == "Second Booker"
      assert second_payload["attendee"]["email"] == "second@example.com"
      assert Enum.map(second_payload["guests"], & &1["email"]) == ["g2@example.com"]

      assert second_payload["seat"] == %{
               "id" => second.id,
               "capacity" => 5,
               "seats_taken" => 4,
               "previous" => nil
             }

      assert first_payload["id"] == meeting.id
      assert second_payload["id"] == meeting.id
    end

    test "Telegram and Slack name each seat's participant", %{params: params} do
      {_meeting, first} = book_seat!(params, "First Booker", "first@example.com")
      {_meeting, second} = book_seat!(params, "Second Booker", "second@example.com")

      telegram = jobs(TelegramWorker, "meeting.created")
      slack = jobs(SlackWorker, "meeting.created")

      assert posted_body!(TelegramWorker, job_for(telegram, first.id)) =~
               "<b>First Booker</b> booked"

      assert posted_body!(TelegramWorker, job_for(telegram, second.id)) =~
               "<b>Second Booker</b> booked"

      assert posted_body!(SlackWorker, job_for(slack, first.id)) =~
               "With First Booker (first@example.com)"

      assert posted_body!(SlackWorker, job_for(slack, second.id)) =~
               "With Second Booker (second@example.com)"
    end
  end

  describe "a seat cancelled" do
    test "reaches every integration as that seat's cancellation", %{params: params} do
      {_meeting, _first} = book_seat!(params, "First Booker", "first@example.com")
      {_meeting, second} = book_seat!(params, "Second Booker", "second@example.com")

      assert {:ok, :seat_cancelled} = CancelSeat.execute(second.management_token)

      assert [job] = jobs(WebhookWorker, "meeting.cancelled")
      assert job.args["participant_id"] == second.id

      payload = webhook_meeting!(job)
      assert payload["attendee"]["email"] == "second@example.com"
      assert payload["status"] == "cancelled"
      {:ok, %{cancelled_at: %DateTime{} = cancelled_at}} = ParticipantQueries.get(second.id)
      assert payload["cancellation"]["cancelled_at"] == DateTime.to_iso8601(cancelled_at)
      assert payload["seat"]["seats_taken"] == 1

      assert [telegram_job] = jobs(TelegramWorker, "meeting.cancelled")

      assert posted_body!(TelegramWorker, telegram_job) =~
               "<b>Second Booker</b> cancelled"

      assert [slack_job] = jobs(SlackWorker, "meeting.cancelled")
      assert posted_body!(SlackWorker, slack_job) =~ "With Second Booker (second@example.com)"
    end

    test "the last seat leaving is one cancellation, for that seat", %{params: params} do
      {meeting, only} = book_seat!(params, "Only Booker", "only@example.com")

      assert {:ok, :meeting_cancelled} = CancelSeat.execute(only.management_token)
      assert Repo.get!(MeetingSchema, meeting.id).status == "cancelled"

      assert [job] = jobs(WebhookWorker, "meeting.cancelled")
      assert job.args["participant_id"] == only.id
      assert webhook_meeting!(job)["attendee"]["email"] == "only@example.com"

      assert [_one] = jobs(TelegramWorker, "meeting.cancelled")
      assert [_one] = jobs(SlackWorker, "meeting.cancelled")
    end
  end

  describe "the host cancelling a group meeting" do
    test "reaches the integrations once per seat that was live", %{params: params} do
      {meeting, first} = book_seat!(params, "First Booker", "first@example.com")
      {_meeting, second} = book_seat!(params, "Second Booker", "second@example.com")
      {_meeting, gone} = book_seat!(params, "Gone Booker", "gone@example.com")
      assert {:ok, :seat_cancelled} = CancelSeat.execute(gone.management_token)

      [gone_job] = jobs(WebhookWorker, "meeting.cancelled")
      Repo.delete_all(Oban.Job)
      assert gone_job.args["participant_id"] == gone.id

      assert {:ok, _cancelled} =
               Cancel.execute(Repo.get!(MeetingSchema, meeting.id), caller: :organizer)

      cancelled = jobs(WebhookWorker, "meeting.cancelled")

      assert cancelled |> Enum.map(& &1.args["participant_id"]) |> Enum.sort() ==
               Enum.sort([first.id, second.id])

      payload = webhook_meeting!(job_for(cancelled, first.id))
      assert payload["attendee"]["email"] == "first@example.com"
      assert payload["status"] == "cancelled"

      assert length(jobs(TelegramWorker, "meeting.cancelled")) == 2
      assert length(jobs(SlackWorker, "meeting.cancelled")) == 2
    end
  end

  describe "a seat moved" do
    test "reaches the integrations as the new seat's reschedule", %{params: params} do
      {old_meeting, mover} = book_seat!(params, "Mover", "mover@example.com")
      {_old_meeting, _stayer} = book_seat!(params, "Stayer", "stayer@example.com")

      new_params = %{
        date: Date.to_iso8601(Date.add(Date.utc_today(), 3)),
        time: "10:00",
        duration: "30min",
        user_timezone: "America/New_York"
      }

      assert {:ok, %{meeting: new_meeting, participant: new_seat}} =
               RescheduleSeat.execute(
                 mover.management_token,
                 new_params,
                 old_meeting.organizer_user_id
               )

      assert [job] = jobs(WebhookWorker, "meeting.rescheduled")
      assert job.args["meeting_id"] == new_meeting.id
      assert job.args["participant_id"] == new_seat.id

      payload = webhook_meeting!(job)
      assert payload["attendee"]["email"] == "mover@example.com"
      assert payload["start_time"] == DateTime.to_iso8601(new_meeting.start_time)
      assert payload["seat"]["id"] == new_seat.id

      # A move gives the seat a new id and a new meeting: the event names the
      # booking it replaces so a consumer can link the two.
      assert payload["seat"]["previous"] == %{
               "seat_id" => mover.id,
               "meeting_id" => old_meeting.id,
               "start_time" => DateTime.to_iso8601(old_meeting.start_time)
             }

      # The old slot still has a seat on it, so nothing about it is cancelled.
      assert jobs(WebhookWorker, "meeting.cancelled") == []

      assert [slack_job] = jobs(SlackWorker, "meeting.rescheduled")
      assert posted_body!(SlackWorker, slack_job) =~ "With Mover (mover@example.com)"
    end
  end

  describe "a solo booking" do
    test "keeps its job arguments and payload shape", %{user: user, webhook: webhook} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          attendee_name: "Solo Attendee",
          attendee_email: "solo@example.com"
        )

      assert :ok = Webhooks.trigger_webhook(webhook, "meeting.created", meeting)

      assert [job] = jobs(WebhookWorker, "meeting.created")

      assert job.args |> Map.keys() |> Enum.sort() ==
               ["event_type", "meeting_id", "snapshot", "webhook_id"]

      refute Map.has_key?(job.args["snapshot"], "seats_taken")

      payload = webhook_meeting!(job)
      assert payload["attendee"]["email"] == "solo@example.com"
      refute Map.has_key?(payload, "seat")
    end
  end
end
