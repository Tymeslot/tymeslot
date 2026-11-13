defmodule Tymeslot.BookingSeries.CancelTest do
  @moduledoc """
  "Cancel all remaining": every session of a series still to come is
  cancelled at once, by its booker or its host, with one series
  cancellation email, a paid series refunded once by the host, and the
  series closed once nothing of it is left. Sessions cancelled one at a
  time close it too, after the last.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.CalendarMock
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.SeriesHostRefund
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    :ok
  end

  defp host(username \\ "grace-host") do
    create_always_bookable_profile(
      timezone: "Etc/UTC",
      profile: %{username: username, full_name: "Grace Hopper"}
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

  defp book(host, type, count) do
    BookingSeries.book(
      %{
        duration: 30,
        user_timezone: "Etc/UTC",
        organizer_user_id: host.user.id,
        meeting_type_id: type.id,
        series: %{mode: :recurring, first_start: Paid.at(7), count: count}
      },
      %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => ""}
    )
  end

  defp meetings,
    do:
      Repo.all(
        from(m in MeetingSchema, where: not is_nil(m.series_id), order_by: m.series_position)
      )

  defp statuses, do: Enum.map(meetings(), & &1.status)

  defp series_seats,
    do:
      Repo.all(
        from(p in ParticipantSchema, where: not is_nil(p.series_id), order_by: p.series_position)
      )

  defp email_jobs(action), do: all_enqueued(worker: EmailWorker, args: %{"action" => action})

  defp jobs(worker, action), do: all_enqueued(worker: worker, args: %{"action" => action})

  defp job_meeting_ids(jobs), do: jobs |> Enum.map(& &1.args["meeting_id"]) |> Enum.sort()

  # Moves a session into the past, as far back as its position in weeks:
  # it has happened.
  defp into_the_past!(meeting) do
    start = DateTime.add(DateTime.utc_now(:second), -7 * meeting.series_position, :day)

    meeting
    |> Changeset.change(start_time: start, end_time: DateTime.add(start, 30, :minute))
    |> Repo.update!()
  end

  defp reload_series(series), do: Repo.get!(SeriesSchema, series.id)

  # The meetings still holding a reminder job.
  defp reminded_ids, do: Enum.uniq(job_meeting_ids(email_jobs("send_reminder_emails")))

  defp statuses_of(seats),
    do: Enum.map(seats, &Repo.get!(MeetingSchema, &1.meeting_id).status)

  defp pay(series, count) do
    event = Paid.completed_event("evt_PAID", series.id, count * Paid.price_cents())
    assert :ok = CheckoutSessionCompleted.handle(event)
  end

  defp expect_refund(amount) do
    expect(StripeAdapterMock, :create_refund, 1, fn params, _opts ->
      assert params.charge == "ch_SERIES"
      assert params.amount == amount
      {:ok, %{id: "re_SERIES"}}
    end)
  end

  defp cancel_as_host(series, host, opts \\ []),
    do:
      BookingSeries.cancel_remaining(
        series,
        [caller: :organizer, acting_user: host.user] ++ opts
      )

  defp refund_jobs, do: all_enqueued(worker: SeriesHostRefund)

  # Runs the one refund job the cancellation inserted.
  defp run_refund_job(opts \\ []) do
    assert [%{args: args}] = refund_jobs()
    perform_job(SeriesHostRefund, args, opts)
  end

  # The payment was taken outside the refund window.
  defp paid_long_ago!(series) do
    series.id
    |> MeetingPayments.payment_for_series()
    |> Changeset.change(paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day))
    |> Repo.update!()
  end

  describe "a one-to-one series" do
    setup do
      host = host()
      type = series_type(host, reminder_config: [%{"value" => 30, "unit" => "minutes"}])
      assert {:ok, %{series: series}} = book(host, type, 4)

      # Each session has a video room to clean up.
      Enum.each(meetings(), fn meeting ->
        meeting |> Changeset.change(video_room_id: "room-#{meeting.id}") |> Repo.update!()
      end)

      %{host: host, series: series}
    end

    test "cancel all remaining cancels future sessions only", %{series: series} do
      [past | future] = meetings()
      into_the_past!(past)
      future_ids = future |> Enum.map(& &1.id) |> Enum.sort()
      assert reminded_ids() -- [past.id] == future_ids

      assert {:ok, %{cancelled: cancelled, refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert cancelled |> Enum.map(& &1.id) |> Enum.sort() == future_ids
      assert statuses() == [:confirmed, :cancelled, :cancelled, :cancelled]

      assert email_jobs("send_cancellation_emails") == []

      assert [%{args: %{"cancelled_by" => "attendee"} = args}] =
               email_jobs("send_series_cancellation")

      assert Enum.sort(args["occurrence_ids"]) == future_ids

      assert job_meeting_ids(jobs(CalendarEventWorker, "delete")) == future_ids
      assert job_meeting_ids(jobs(VideoSyncWorker, "delete")) == future_ids
      assert reminded_ids() -- [past.id] == []

      # The past session is still there, so is the series' record of it,
      # but nothing of it is left to come.
      assert %DateTime{} = reload_series(series).cancelled_at
    end

    test "the host cancels with the host's wording", %{host: host, series: series} do
      assert {:ok, %{cancelled: [_first, _second, _third, _fourth]}} =
               BookingSeries.cancel_remaining(series, caller: :organizer, acting_user: host.user)

      assert [%{args: %{"cancelled_by" => "organizer"}}] = email_jobs("send_series_cancellation")
    end

    test "another host cannot cancel the series", %{series: series} do
      intruder = host("other-host")

      assert {:error, :not_found} = BookingSeries.get_for_organizer(series.id, intruder.user.id)

      assert {:error, :not_found} =
               BookingSeries.cancel_remaining(series,
                 caller: :organizer,
                 acting_user: intruder.user
               )

      assert {:error, :not_found} = BookingSeries.cancel_remaining(series, caller: :organizer)

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
    end

    test "the host finds their own series, the attendee theirs by uid", %{
      host: host,
      series: series
    } do
      assert {:ok, %SeriesSchema{id: id}} =
               BookingSeries.get_for_organizer(series.id, host.user.id)

      assert id == series.id

      assert {:ok, %SeriesSchema{id: ^id}} = BookingSeries.get_for_attendee(series.uid)
      assert {:error, :not_found} = BookingSeries.get_for_attendee("not-a-uid")
      assert {:error, :not_found} = BookingSeries.get_for_attendee(UUID.generate())
      assert {:error, :not_found} = BookingSeries.get_for_organizer("not-an-id", host.user.id)

      assert series |> BookingSeries.occurrences() |> Enum.map(& &1.series_position) ==
               [1, 2, 3, 4]
    end

    test "nothing left to cancel", %{series: series} do
      Enum.each(meetings(), &into_the_past!/1)

      assert {:error, :nothing_to_cancel} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
      assert is_nil(reload_series(series).cancelled_at)
    end

    test "a second cancel-all is a no-op", %{series: series} do
      assert {:ok, _cancelled} = BookingSeries.cancel_remaining(series, caller: :attendee)

      assert {:error, :nothing_to_cancel} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert [_one] = email_jobs("send_series_cancellation")
    end

    test "a calendar deletion of the last session closes the series", %{series: series} do
      [first, second, third, fourth] = meetings()

      for meeting <- [first, second, third] do
        assert {:ok, _cancelled} = Meetings.cancel_meeting(meeting)
      end

      assert is_nil(reload_series(series).cancelled_at)

      assert {:ok, _cancelled} = Cancel.execute_external(fourth)
      assert %DateTime{} = reload_series(series).cancelled_at
    end

    test "cancelling each session alone closes the series after the last", %{series: series} do
      [first, second, third, fourth] = meetings()

      for meeting <- [first, second, third] do
        assert {:ok, _cancelled} = Meetings.cancel_meeting(meeting)
      end

      assert is_nil(reload_series(series).cancelled_at)

      assert {:ok, _cancelled} = Meetings.cancel_meeting(fourth)

      assert %DateTime{} = reload_series(series).cancelled_at
      # Each was told on its own, and the series sent nothing more.
      assert length(email_jobs("send_cancellation_emails")) == 4
      assert email_jobs("send_series_cancellation") == []
    end
  end

  describe "a group series" do
    setup do
      host = host()
      type = series_type(host, max_participants: 3)
      assert {:ok, %{series: series, meetings: sessions}} = book(host, type, 3)
      %{host: host, series: series, sessions: sessions}
    end

    test "a group series gives up every future seat", %{series: series, sessions: sessions} do
      [first, second, third] = sessions
      other = insert(:participant, meeting: second, email: "alan@example.com")

      assert {:ok, %{cancelled: cancelled, refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      seats = series_seats()
      assert Enum.all?(seats, &(not ParticipantSchema.live?(&1)))

      assert cancelled |> Enum.map(& &1.id) |> Enum.sort() ==
               seats |> Enum.map(& &1.id) |> Enum.sort()

      # Sessions the series was alone in go with it; the shared one stays.
      assert Repo.reload!(first).status == :cancelled
      assert Repo.reload!(third).status == :cancelled
      assert Repo.reload!(second).status == :confirmed
      assert ParticipantSchema.live?(Repo.reload!(other))

      assert email_jobs("send_seat_cancellation_emails") == []
      assert [%{args: args}] = email_jobs("send_series_cancellation")
      assert Enum.sort(args["occurrence_ids"]) == seats |> Enum.map(& &1.id) |> Enum.sort()

      assert %DateTime{} = reload_series(series).cancelled_at
    end

    test "an emptied session sends no meeting cancellation of its own", %{series: series} do
      assert {:ok, _cancelled} = BookingSeries.cancel_remaining(series, caller: :attendee)

      assert statuses_of(series_seats()) == [:cancelled, :cancelled, :cancelled]
      assert email_jobs("send_cancellation_emails") == []
      assert email_jobs("send_seat_cancellation_emails") == []
      assert [_one] = email_jobs("send_series_cancellation")
    end

    test "the host cancels a group series", %{host: host, series: series, sessions: sessions} do
      [_first, second, _third] = sessions
      other = insert(:participant, meeting: second, email: "alan@example.com")

      assert {:ok, %{cancelled: [_s1, _s2, _s3], refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :organizer, acting_user: host.user)

      assert Enum.all?(series_seats(), &(not ParticipantSchema.live?(&1)))
      assert Repo.reload!(second).status == :confirmed
      assert ParticipantSchema.live?(Repo.reload!(other))
      assert [%{args: %{"cancelled_by" => "organizer"}}] = email_jobs("send_series_cancellation")
    end

    test "giving up each seat alone closes the series after the last", %{series: series} do
      [first, second, third] = series_seats()

      assert {:ok, _given_up} = Meetings.cancel_seat(first.management_token)
      assert {:ok, _given_up} = Meetings.cancel_seat(second.management_token)
      assert is_nil(reload_series(series).cancelled_at)

      assert {:ok, _given_up} = Meetings.cancel_seat(third.management_token)
      assert %DateTime{} = reload_series(series).cancelled_at
    end
  end

  describe "a paid series" do
    setup do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true
      )

      # The completed webhook backfills the charge the refunds are made on.
      stub(StripeAdapterMock, :retrieve_payment_intent, fn "pi_SERIES", _opts ->
        {:ok, %{"latest_charge" => "ch_SERIES"}}
      end)

      host = Paid.paid_host()
      Paid.expect_checkout()

      assert {:ok, :payment_required, %{series: series}} =
               Paid.book(host, Paid.paid_series_type(host), 4)

      %{host: host, series: series, payment: MeetingPayments.payment_for_series(series.id)}
    end

    test "the host's default refund for a paid series is the remaining sessions' share", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      meetings() |> hd() |> into_the_past!()

      assert {:ok, %{cancelled: [_second, _third, _fourth], refund: {:scheduled, 15_000}}} =
               cancel_as_host(series, host)

      assert statuses() == [:confirmed, :cancelled, :cancelled, :cancelled]
      # Nothing is refunded until the job runs, outside the cancellation.
      assert Repo.reload!(payment).refunded_amount_cents == 0

      expect_refund(15_000)
      assert :ok = run_refund_job()

      assert %{refunded_amount_cents: 15_000, status: :partially_refunded} =
               Repo.reload!(payment)

      # A retry after the refund was recorded asks Stripe for nothing more.
      assert :ok = run_refund_job()
      assert Repo.reload!(payment).refunded_amount_cents == 15_000
    end

    test "the default refund is capped at what an earlier refund left", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      [first | _rest] = meetings()

      expect_refund(16_000)

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(first, host.user.id, {:refund, 16_000})

      assert {:ok, %{cancelled: [_second, _third, _fourth], refund: {:scheduled, 4_000}}} =
               cancel_as_host(series, host)

      expect_refund(4_000)
      assert :ok = run_refund_job()
      assert %{refunded_amount_cents: 20_000, status: :refunded} = Repo.reload!(payment)
    end

    test "a custom amount", %{host: host, series: series, payment: payment} do
      pay(series, 4)

      assert {:ok, %{refund: {:scheduled, 2_000}}} =
               cancel_as_host(series, host, refund: {:amount, 2_000})

      expect_refund(2_000)
      assert :ok = run_refund_job()
      assert Repo.reload!(payment).refunded_amount_cents == 2_000
    end

    test "no refund", %{host: host, series: series, payment: payment} do
      pay(series, 4)

      assert {:ok, %{cancelled: [_first, _second, _third, _fourth], refund: :none}} =
               cancel_as_host(series, host, refund: :none)

      assert refund_jobs() == []
      assert Repo.reload!(payment).refunded_amount_cents == 0
    end

    test "an amount above what remains is refused before anything is cancelled", %{
      host: host,
      series: series
    } do
      pay(series, 4)

      assert {:error, :exceeds_remaining} =
               cancel_as_host(series, host, refund: {:amount, 4 * Paid.price_cents() + 1})

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
      assert refund_jobs() == []
    end

    test "past the refund window, the default cancels without a refund and says why", %{
      host: host,
      series: series
    } do
      pay(series, 4)
      paid_long_ago!(series)

      assert {:ok,
              %{
                cancelled: [_first, _second, _third, _fourth],
                refund: {:not_refunded, :outside_refund_window}
              }} = cancel_as_host(series, host)

      assert refund_jobs() == []
    end

    test "past the refund window, an explicit amount is refused with nothing cancelled", %{
      host: host,
      series: series
    } do
      pay(series, 4)
      paid_long_ago!(series)

      assert {:error, :outside_refund_window} =
               cancel_as_host(series, host, refund: {:amount, 1_000})

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
    end

    test "an attendee cancellation of a paid series refunds nothing", %{
      series: series,
      payment: payment
    } do
      pay(series, 4)

      assert {:ok, %{cancelled: [_first, _second, _third, _fourth], refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert refund_jobs() == []
      assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
    end

    test "sessions awaiting payment are left to the checkout", %{host: host, series: series} do
      assert {:error, :nothing_to_cancel} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert {:error, :nothing_to_cancel} = cancel_as_host(series, host)

      # An explicit amount on a payment still to be made says so.
      assert {:error, :not_paid} = cancel_as_host(series, host, refund: {:amount, 1_000})

      assert statuses() == [
               :awaiting_payment,
               :awaiting_payment,
               :awaiting_payment,
               :awaiting_payment
             ]

      assert email_jobs("send_series_cancellation") == []
      assert is_nil(reload_series(series).cancelled_at)
    end

    test "a refund failure leaves the sessions cancelled and reports it", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)

      assert {:ok, %{refund: {:scheduled, 20_000}}} = cancel_as_host(series, host)
      assert statuses() == [:cancelled, :cancelled, :cancelled, :cancelled]
      assert [_one] = email_jobs("send_series_cancellation")

      expect(StripeAdapterMock, :create_refund, 2, fn _params, _opts -> {:error, :api_error} end)

      # A failed attempt is retried; a refusal no retry turns round is
      # discarded. Either way the money stays on the payment.
      assert {:error, :api_error} = run_refund_job(attempt: 1)
      assert {:error, :api_error} = run_refund_job(attempt: 10)
      paid_long_ago!(series)
      assert {:discard, :outside_refund_window} = run_refund_job(attempt: 2)

      assert Repo.reload!(payment).refunded_amount_cents == 0
    end
  end

  describe "a series held for approval" do
    test "an open approval request is withdrawn as a whole" do
      host = host()
      type = series_type(host, requires_approval: true, approval_window_hours: 48)
      assert {:ok, %{series: series}} = book(host, type, 3)
      assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]

      assert {:ok, %{cancelled: [_first, _second, _third], refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert email_jobs("send_cancellation_emails") == []

      assert [%{args: %{"cancelled_by" => "attendee"}}] =
               email_jobs("send_series_cancellation")

      assert {:error, :nothing_to_cancel} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert %DateTime{} = reload_series(series).cancelled_at
    end

    test "a declined or expired series request is closed" do
      host = host()
      type = series_type(host, requires_approval: true, approval_window_hours: 48)
      assert {:ok, %{series: declined}} = book(host, type, 2)
      assert {:ok, _released} = SeriesApproval.decline(declined, host.user, nil)
      assert %DateTime{} = reload_series(declined).cancelled_at

      other = series_type(host, requires_approval: true, approval_window_hours: 48, name: "Other")
      assert {:ok, %{series: expired}} = book(host, other, 2)
      assert {:ok, _released} = SeriesApproval.expire(expired)
      assert %DateTime{} = reload_series(expired).cancelled_at
    end

    test "the host cancelling an open paid request refunds it in full, whatever the option" do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true
      )

      stub(StripeAdapterMock, :retrieve_payment_intent, fn "pi_SERIES", _opts ->
        {:ok, %{"latest_charge" => "ch_SERIES"}}
      end)

      host = Paid.paid_host()

      type =
        host
        |> Paid.paid_series_type()
        |> Changeset.change(requires_approval: true)
        |> Repo.update!()

      Paid.expect_checkout()
      assert {:ok, :payment_required, %{series: series}} = Paid.book(host, type, 3)
      pay(series, 3)
      assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]

      expect_refund(15_000)

      assert {:ok, %{cancelled: [_first, _second, _third], refund: {:refunded, 15_000}}} =
               cancel_as_host(series, host, refund: :none)

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert refund_jobs() == []

      assert [%{args: %{"cancelled_by" => "organizer"}}] =
               email_jobs("send_series_cancellation")
    end
  end
end
