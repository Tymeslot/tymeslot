defmodule Tymeslot.Webhooks.SeriesPayloadTest do
  @moduledoc """
  A booking series reaches the host's automations as one event: one
  `meeting.series_created` once it is confirmed (free, paid or approved),
  one `meeting.series_cancelled` for "Cancel all remaining", and no
  `meeting.created` or `meeting.cancelled` per session. Events about one
  session carry its place in the series; a single booking carries
  `"series": null`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :automation
  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Oban.Job
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.CalendarMock
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.ChannelFanout
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Slack.MessageBuilder
  alias Tymeslot.Telegram.MessageBuilder, as: TelegramMessageBuilder
  alias Tymeslot.Webhooks
  alias Tymeslot.Workers.SeriesAnnouncementWorker
  alias Tymeslot.Workers.SeriesAutomationWorker
  alias Tymeslot.Workers.SlackWorker
  alias Tymeslot.Workers.TelegramWorker
  alias Tymeslot.Workers.WebhookWorker
  alias TymeslotWeb.Dashboard.Automation.EventSubscriptions

  @every_event [
    "meeting.created",
    "meeting.series_created",
    "meeting.cancelled",
    "meeting.series_cancelled",
    "meeting.requested",
    "meeting.series_requested",
    "meeting.declined",
    "meeting.series_declined",
    "meeting.request_expired",
    "meeting.series_request_expired"
  ]

  defmodule NoAutomations do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :automations_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      slack_notifications_allowed: true
    )

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    :ok
  end

  defp host do
    create_always_bookable_profile(
      timezone: "Etc/UTC",
      profile: %{username: "grace-host", full_name: "Grace Hopper"}
    )
  end

  defp series_type(host, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: host.user,
          name: "Mentoring",
          duration_minutes: 30,
          series_mode: :recurring,
          series_frequency: :weekly,
          series_interval: 1,
          series_min_occurrences: 2,
          series_max_occurrences: 12
        ],
        attrs
      )
    )
  end

  defp subscribe(host, events \\ @every_event),
    do: insert(:webhook, user: host.user, events: events)

  defp book(host, type, count, message \\ "") do
    BookingSeries.book(
      %{
        duration: 30,
        user_timezone: "Etc/UTC",
        organizer_user_id: host.user.id,
        meeting_type_id: type.id,
        series: %{mode: :recurring, first_start: Paid.at(7), count: count}
      },
      %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => message}
    )
  end

  defp deliveries(event), do: all_enqueued(worker: WebhookWorker, args: %{"event_type" => event})

  defp sessions do
    Repo.all(
      from(m in MeetingSchema, where: not is_nil(m.series_id), order_by: m.series_position)
    )
  end

  defp statuses_of_series, do: Enum.map(sessions(), & &1.status)

  defp positions(sessions), do: Enum.map(sessions, & &1["position"])

  # Runs the series' confirmation, then the automation job it queued.
  defp announce(series) do
    assert :ok = perform_job(SeriesAnnouncementWorker, %{"series_id" => series.id})
    run_automation()
  end

  defp run_automation do
    assert [%Job{args: args}] = all_enqueued(worker: SeriesAutomationWorker)
    assert :ok = perform_job(SeriesAutomationWorker, args)
    args
  end

  # Posts a delivery job and returns the JSON body the receiver got.
  defp posted_body(%Job{args: args}) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, body, _headers, _opts ->
      send(test_pid, {:posted, body})
      {:ok, %{status: 200, body: "ok"}}
    end)

    assert :ok = perform_job(WebhookWorker, args)
    assert_received {:posted, body}
    Jason.decode!(body)
  end

  test "booking a series fires one series_created and no booking created" do
    host = host()
    subscribe(host)
    assert {:ok, %{series: series}} = book(host, series_type(host), 3)

    assert deliveries("meeting.created") == []
    assert deliveries("meeting.series_created") == []

    announce(series)

    assert deliveries("meeting.created") == []
    assert [delivery] = deliveries("meeting.series_created")

    [first | _rest] = sessions = sessions()
    body = posted_body(delivery)

    assert body["event"] == "meeting.series_created"
    assert body["data"]["meeting"]["id"] == first.id
    assert body["data"]["meeting"]["managed_by_host"] == false

    assert %{
             "id" => series_id,
             "mode" => "recurring",
             "count" => 3,
             "rule" => rule,
             "sessions" => posted_sessions
           } = body["data"]["series"]

    assert series_id == series.id
    assert rule =~ "Every week on"

    assert Enum.map(posted_sessions, &{&1["position"], &1["meeting_uid"], &1["status"]}) ==
             Enum.map(sessions, &{&1.series_position, &1.uid, "confirmed"})

    # A confirmation run again (a rescued announcement job) announces
    # nothing twice, once the first event's job has run.
    Repo.update_all(
      from(j in Job, where: j.worker == "Tymeslot.Workers.SeriesAutomationWorker"),
      set: [state: "completed", completed_at: DateTime.utc_now()]
    )

    assert :ok = perform_job(SeriesAnnouncementWorker, %{"series_id" => series.id})
    assert all_enqueued(worker: SeriesAutomationWorker) == []
  end

  test "a paid series fires series_created only when paid" do
    setup_config(:tymeslot, meeting_payments_enabled: true)
    host = Paid.paid_host()
    subscribe(host)
    Paid.expect_checkout()

    assert {:ok, :payment_required, %{series: series}} =
             Paid.book(host, Paid.paid_series_type(host), 2)

    refute_enqueued(worker: SeriesAnnouncementWorker)
    refute_enqueued(worker: SeriesAutomationWorker)
    assert deliveries("meeting.created") == []

    event = Paid.completed_event("evt_PAID", series.id, 2 * Paid.price_cents())
    assert :ok = CheckoutSessionCompleted.handle(event)

    assert deliveries("meeting.created") == []

    announce(series)

    assert deliveries("meeting.created") == []
    assert [_one] = deliveries("meeting.series_created")
  end

  test "an approved series fires series_created on approval" do
    host = host()
    subscribe(host)

    assert {:ok, %{series: series}} =
             book(host, series_type(host, requires_approval: true), 2)

    Repo.delete_all(from(j in Job, where: j.worker == "Tymeslot.Workers.SeriesAutomationWorker"))
    assert {:ok, _confirmed} = SeriesApproval.approve(series, host.user)

    assert deliveries("meeting.created") == []
    refute_enqueued(worker: SeriesAutomationWorker)

    announce(series)

    assert deliveries("meeting.created") == []
    assert [_one] = deliveries("meeting.series_created")
  end

  describe "a series held for approval" do
    setup do
      host = host()
      subscribe(host)
      assert {:ok, %{series: series}} = book(host, series_type(host, requires_approval: true), 3)
      %{host: host, series: series}
    end

    test "is requested once, naming every held session", %{series: series} do
      assert deliveries("meeting.requested") == []
      assert %{"event_type" => "meeting.series_requested"} = run_automation()

      assert deliveries("meeting.requested") == []
      assert [delivery] = deliveries("meeting.series_requested")
      body = posted_body(delivery)

      assert body["data"]["meeting"]["id"] == hd(sessions()).id
      assert body["data"]["series"]["id"] == series.id

      assert Enum.map(body["data"]["series"]["sessions"], &{&1["position"], &1["status"]}) ==
               [{1, "awaiting_approval"}, {2, "awaiting_approval"}, {3, "awaiting_approval"}]
    end

    test "a decline fires one series_declined", %{host: host, series: series} do
      Repo.delete_all(
        from(j in Job, where: j.worker == "Tymeslot.Workers.SeriesAutomationWorker")
      )

      assert {:ok, _released} = SeriesApproval.decline(series, host.user, "Fully booked")
      assert %{"event_type" => "meeting.series_declined"} = run_automation()

      assert deliveries("meeting.declined") == []
      assert [delivery] = deliveries("meeting.series_declined")

      assert delivery |> posted_body() |> get_in(["data", "series", "sessions"]) |> positions() ==
               [1, 2, 3]
    end

    test "an expiry fires one series_request_expired", %{series: series} do
      Repo.delete_all(
        from(j in Job, where: j.worker == "Tymeslot.Workers.SeriesAutomationWorker")
      )

      assert {:ok, _released} = SeriesApproval.expire(series)
      assert %{"event_type" => "meeting.series_request_expired"} = run_automation()

      assert deliveries("meeting.request_expired") == []
      assert [_one] = deliveries("meeting.series_request_expired")
    end

    test "a withdrawal fires one series_cancelled", %{series: series} do
      Repo.delete_all(
        from(j in Job, where: j.worker == "Tymeslot.Workers.SeriesAutomationWorker")
      )

      assert {:ok, _withdrawn} =
               BookingSeries.cancel_remaining(series, caller: :attendee, expect: :withdraw)

      assert %{"event_type" => "meeting.series_cancelled"} = run_automation()
      assert deliveries("meeting.cancelled") == []
      assert [_one] = deliveries("meeting.series_cancelled")
    end

    test "Slack and Telegram word the request for the series", %{series: series} do
      summary = %{"count" => 3, "sessions" => [%{}, %{}, %{}], "id" => series.id}
      [first | _rest] = sessions()

      texts =
        "meeting.series_requested"
        |> MessageBuilder.build_blocks(first, "Etc/UTC", summary)
        |> Enum.map(&get_in(&1, ["text", "text"]))

      assert "New series request" in texts

      assert Enum.any?(
               texts,
               &(is_binary(&1) and &1 =~ "*Ada Lovelace* asked for 3 sessions of *Mentoring*")
             )

      assert TelegramMessageBuilder.build_message(
               "meeting.series_declined",
               first,
               "Etc/UTC",
               summary
             ) =~ "<b>Ada Lovelace</b>'s request for 3 sessions of <i>Mentoring</i> was declined"
    end
  end

  test "cancel all remaining fires one series_cancelled" do
    host = host()
    subscribe(host)
    assert {:ok, %{series: series}} = book(host, series_type(host), 3)
    announce(series)
    Repo.delete_all(from(j in Job, where: j.worker != "Tymeslot.Workers.WebhookWorker"))

    assert {:ok, %{cancelled: cancelled}} =
             BookingSeries.cancel_remaining(series, caller: :attendee)

    assert length(cancelled) == 3
    assert deliveries("meeting.cancelled") == []

    run_automation()

    assert deliveries("meeting.cancelled") == []
    assert [delivery] = deliveries("meeting.series_cancelled")

    body = posted_body(delivery)
    assert body["data"]["series"]["id"] == series.id

    assert Enum.map(body["data"]["series"]["sessions"], & &1["status"]) ==
             ["cancelled", "cancelled", "cancelled"]
  end

  test "cancelling one session fires the usual cancel with series fields" do
    host = host()
    subscribe(host)
    assert {:ok, %{series: series}} = book(host, series_type(host), 3)
    [_first, second, _third] = sessions()

    assert {:ok, _cancelled} = Cancel.execute(second, caller: :attendee)

    refute_enqueued(worker: SeriesAutomationWorker)
    assert [delivery] = deliveries("meeting.cancelled")

    body = posted_body(delivery)
    assert body["data"]["meeting"]["id"] == second.id
    assert body["data"]["series"] == %{"id" => series.id, "position" => 2, "count" => 3}
  end

  test "a single booking carries series null" do
    host = host()
    subscribe(host)
    meeting = insert(:meeting, organizer_user_id: host.user.id)

    assert :ok = ChannelFanout.dispatch(:meeting_created, meeting)
    assert [delivery] = deliveries("meeting.created")

    body = posted_body(delivery)
    assert Map.fetch!(body["data"], "series") == nil
  end

  test "Slack gets one message for a series" do
    host = host()

    insert(:slack_integration,
      user: host.user,
      events: ["meeting.created", "meeting.series_created"]
    )

    assert {:ok, %{series: series}} = book(host, series_type(host), 4, "Weekly please")
    announce(series)

    assert [%Job{args: %{"event_type" => "meeting.series_created", "series" => summary}}] =
             all_enqueued(worker: SlackWorker)

    [first | _rest] = sessions()
    blocks = MessageBuilder.build_blocks("meeting.series_created", first, "Etc/UTC", summary)

    texts = Enum.map(blocks, &get_in(&1, ["text", "text"]))
    assert "New series booked" in texts

    assert Enum.any?(
             texts,
             &(is_binary(&1) and &1 =~ "*Ada Lovelace* booked 4 sessions of *Mentoring*")
           )

    # The booker's notes, as a single booking's message carries them.
    assert Enum.any?(texts, &(is_binary(&1) and &1 =~ "Weekly please"))
  end

  test "a group series fires one series_created and no seat booked" do
    host = host()
    subscribe(host)
    type = series_type(host, max_participants: 3)

    assert {:ok, %{series: series}} = book(host, type, 3)

    assert deliveries("meeting.created") == []

    announce(series)

    assert deliveries("meeting.created") == []
    assert [delivery] = deliveries("meeting.series_created")
    assert delivery.args["participant_id"]

    body = posted_body(delivery)
    assert body["data"]["meeting"]["attendee"]["email"] == "ada@example.com"
    assert Enum.map(body["data"]["series"]["sessions"], & &1["position"]) == [1, 2, 3]
    assert Enum.all?(body["data"]["series"]["sessions"], &is_binary(&1["seat_id"]))
  end

  test "an event about one seat of a group series carries the seat's place" do
    host = host()
    subscribe(host)
    assert {:ok, %{series: series}} = book(host, series_type(host, max_participants: 3), 3)

    seat =
      Repo.one!(
        from(p in ParticipantSchema,
          where: p.series_id == ^series.id and p.series_position == 2,
          preload: :meeting
        )
      )

    assert :ok = ChannelFanout.dispatch(:meeting_cancelled, SeatView.at_event(seat.meeting, seat))
    assert [delivery] = deliveries("meeting.cancelled")

    assert posted_body(delivery)["data"]["series"] ==
             %{"id" => series.id, "position" => 2, "count" => 3}
  end

  test "Telegram gets one message for a series" do
    setup_config(:tymeslot, telegram_notifications_allowed: true)
    host = host()

    insert(:telegram_integration,
      user: host.user,
      events: ["meeting.created", "meeting.series_created"]
    )

    assert {:ok, %{series: series}} = book(host, series_type(host), 2, "Weekly please")
    announce(series)

    assert [%Job{args: %{"series" => summary}}] = all_enqueued(worker: TelegramWorker)

    [first | _rest] = sessions()
    first = %{first | organizer_video_url: "https://meet.example.com/first-session"}

    message =
      TelegramMessageBuilder.build_message("meeting.series_created", first, "Etc/UTC", summary)

    assert message =~ "<b>Ada Lovelace</b> booked 2 sessions of <i>Mentoring</i>, starting"
    assert message =~ "ada@example.com"
    # The booker's notes and the first session's join link, as a single
    # booking's message carries them.
    assert message =~ "Weekly please"

    assert message =~
             ~s(<a href="https://meet.example.com/first-session">Join the first session</a>)
  end

  test "a late payment for a lapsed series fires series_created once and no booking created" do
    setup_config(:tymeslot, meeting_payments_enabled: true)
    host = Paid.paid_host()
    subscribe(host)
    Paid.expect_checkout()

    stub(StripeAdapterMock, :retrieve_payment_intent, fn _intent, _opts ->
      {:ok, %{"latest_charge" => "ch_SERIES"}}
    end)

    assert {:ok, :payment_required, %{series: series}} =
             Paid.book(host, Paid.paid_series_type(host), 2)

    assert :ok = CheckoutSessionExpired.handle(Paid.expired_event("evt_LAPSED", series.id))

    event = Paid.completed_event("evt_LATE", series.id, 2 * Paid.price_cents())
    assert :ok = CheckoutSessionCompleted.handle(event)
    assert statuses_of_series() == [:confirmed, :confirmed]

    announce(series)

    assert deliveries("meeting.created") == []
    assert [_one] = deliveries("meeting.series_created")
  end

  test "cancel all remaining lists only the sessions it cancelled" do
    host = host()
    subscribe(host)
    assert {:ok, %{series: series}} = book(host, series_type(host), 3)
    [_first, second, _third] = sessions()
    assert {:ok, _cancelled} = Cancel.execute(second, caller: :attendee)
    Repo.delete_all(Job)

    assert {:ok, %{cancelled: [_one, _two]}} =
             BookingSeries.cancel_remaining(series, caller: :attendee)

    run_automation()
    assert [delivery] = deliveries("meeting.series_cancelled")

    assert delivery |> posted_body() |> get_in(["data", "series", "sessions"]) |> positions() ==
             [1, 3]
  end

  test "a host without automations gets no series events" do
    setup_config(:tymeslot, feature_access_checker: NoAutomations)
    host = host()
    subscribe(host)
    assert {:ok, %{series: series}} = book(host, series_type(host), 2)

    announce(series)
    assert all_enqueued(worker: WebhookWorker) == []

    Repo.delete_all(from(j in Job, where: j.worker == "Tymeslot.Workers.SeriesAutomationWorker"))
    assert {:ok, _cancelled} = BookingSeries.cancel_remaining(series, caller: :attendee)
    run_automation()
    assert all_enqueued(worker: WebhookWorker) == []
  end

  describe "subscribing" do
    test "the series events can be chosen for a webhook" do
      host = host()
      values = Enum.map(Webhooks.available_events(), & &1.value)
      assert "meeting.series_created" in values
      assert "meeting.series_cancelled" in values

      html =
        render_component(&EventSubscriptions.event_subscriptions/1,
          name: "webhook[events][]",
          events: Webhooks.available_events(),
          selected: [],
          toggle_event: "toggle_event",
          target: "#automation",
          description: "Pick events"
        )

      assert html =~ ~s(value="meeting.series_created")
      assert html =~ ~s(value="meeting.series_cancelled")

      assert {:ok, webhook} =
               Webhooks.create_webhook(host.user.id, %{
                 name: "Courses",
                 url: "https://example.com/hook",
                 events: ["meeting.series_created", "meeting.series_cancelled"]
               })

      assert webhook.events == ["meeting.series_created", "meeting.series_cancelled"]
    end
  end
end
