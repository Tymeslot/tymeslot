defmodule Tymeslot.MeetingPayments.Webhooks.PaymentTransitionsConcurrencyTest do
  @moduledoc """
  Races between the Connect webhook handlers that move one booking payment,
  on real connections, staged by `Tymeslot.Test.RaceConductor` (see its
  moduledoc for why the module is synchronous and why `on_exit` deletes what
  it committed).

  Each handler resolves its row before opening a transaction, so without a
  row lock taken inside the transaction a contender decides from a copy that
  another handler has since moved on.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :webhooks
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreated
  alias Tymeslot.MeetingPayments.Webhooks.ChargeRefunded
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  @account "acct_RACE_HOST"
  @succeeded [:tymeslot, :meeting_payments, :booking_payment, :succeeded]

  setup do
    user =
      unboxed(fn ->
        user = insert(:user)
        insert(:profile, user: user)
        user
      end)

    on_exit(fn ->
      unboxed(fn ->
        meeting_ids =
          Repo.all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id, select: m.id))

        payment_ids =
          Repo.all(
            from(b in BookingPaymentSchema, where: b.host_user_id == ^user.id, select: b.id)
          )

        Repo.delete_all(
          from(j in Oban.Job,
            where:
              fragment("?->>'meeting_id'", j.args) in ^meeting_ids or
                fragment("?->>'booking_payment_id'", j.args) in ^payment_ids
          )
        )

        Repo.delete_all(from(b in BookingPaymentSchema, where: b.host_user_id == ^user.id))

        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user}
  end

  # The cron reconciler replays `checkout.session.completed` under its own
  # synthetic event id, so the replay guard on `last_event_id` cannot tell it
  # apart from Stripe's own retry of the same completion.
  test "a webhook and the reconciler completing one payment activate the booking once", ctx do
    test_pid = self()
    handler_id = "count-activations-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach(
        handler_id,
        @succeeded,
        fn _event, _measurements, _metadata, _config -> send(test_pid, :activated) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {meeting, _payment} = awaiting_payment_booking(ctx.user, "cs_RACE_DOUBLE")

    results =
      race([
        fn hold -> complete(hold, "evt_RACE_DOUBLE", meeting) end,
        fn hold -> complete(hold, "reconcile:cs_RACE_DOUBLE", meeting) end
      ])

    assert results == [:ok, :ok]
    assert_received :activated
    refute_received :activated
    assert unboxed(fn -> Repo.get!(MeetingSchema, meeting.id).status end) == "confirmed"
  end

  test "a lost dispute racing a larger refund keeps the larger refunded amount", ctx do
    payment =
      unboxed(fn ->
        insert(:paid_booking_payment,
          host_user_id: ctx.user.id,
          stripe_account_id: @account,
          stripe_charge_id: "ch_RACE_REFUND"
        )
      end)

    results =
      race([
        fn hold ->
          # Parks holding the row it has just written, before committing.
          RaceConductor.arm(hold, update_of("booking_payments"))

          ChargeRefunded.handle(
            charge_event("evt_REFUNDED", payment, %{"amount_refunded" => 3000})
          )
        end,
        fn hold ->
          # Parks right after resolving the row, before the refund commits.
          RaceConductor.arm(hold, read_of("booking_payments"))

          ChargeDisputeClosed.handle(
            charge_event("evt_DISPUTE_LOST", payment, %{
              "charge" => payment.stripe_charge_id,
              "status" => "lost",
              "amount" => 2000
            })
          )
        end
      ])

    assert results == [:ok, :ok]

    reloaded = unboxed(fn -> Repo.get!(BookingPaymentSchema, payment.id) end)
    assert reloaded.refunded_amount_cents == 3000
    assert reloaded.status == "partially_refunded"
  end

  # A charge can be disputed the instant it is captured, so the dispute can
  # commit between the completion resolving its row and writing it.
  test "a dispute committing while a completion is under way stays disputed", ctx do
    {meeting, payment} = awaiting_payment_booking(ctx.user, "cs_RACE_DISPUTE")

    unboxed(fn ->
      Repo.update!(Changeset.change(payment, stripe_payment_intent_id: "pi_RACE_DOUBLE"))
    end)

    Mox.stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
      {:ok, %{"latest_charge" => "ch_RACE_DISPUTE"}}
    end)

    results =
      race([
        fn hold ->
          # Parks right after resolving the row, before the dispute commits.
          RaceConductor.arm(hold, read_of("booking_payments"))
          complete(nil, "evt_RACE_COMPLETED", meeting, "cs_RACE_DISPUTE")
        end,
        fn _hold ->
          ChargeDisputeCreated.handle(%{
            "id" => "evt_RACE_DISPUTED",
            "account" => @account,
            "data" => %{
              "object" => %{
                "id" => "dp_RACE",
                "charge" => "ch_RACE_DISPUTE",
                "payment_intent" => "pi_RACE_DOUBLE",
                "amount" => 5000
              }
            }
          })
        end
      ])

    assert results == [:ok, :ok]

    reloaded = unboxed(fn -> Repo.get!(BookingPaymentSchema, payment.id) end)
    assert reloaded.status == "disputed"
    assert reloaded.last_event_id == "evt_RACE_COMPLETED"
    assert unboxed(fn -> Repo.get!(MeetingSchema, meeting.id).status end) == "confirmed"
  end

  # Stripe can deliver a session's expiry while its completion is being
  # handled; once the payment is taken, the expiry has nothing left to fail.
  test "an expiry arriving while a completion commits leaves the booking paid", ctx do
    {meeting, payment} = awaiting_payment_booking(ctx.user, "cs_RACE_EXPIRY")

    Mox.stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
      {:ok, %{"latest_charge" => "ch_RACE_EXPIRY"}}
    end)

    results =
      race([
        fn _hold -> complete(nil, "evt_RACE_PAID", meeting, "cs_RACE_EXPIRY") end,
        fn hold ->
          # Parks right after resolving the row, before the completion commits.
          RaceConductor.arm(hold, read_of("booking_payments"))

          CheckoutSessionExpired.handle(%{
            "id" => "evt_RACE_EXPIRED",
            "account" => @account,
            "type" => "checkout.session.expired",
            "data" => %{
              "object" => %{"id" => "cs_RACE_EXPIRY", "client_reference_id" => meeting.id}
            }
          })
        end
      ])

    assert results == [:ok, :ok]

    reloaded = unboxed(fn -> Repo.get!(BookingPaymentSchema, payment.id) end)
    assert reloaded.status == "paid"
    assert reloaded.last_event_id == "evt_RACE_PAID"
    assert unboxed(fn -> Repo.get!(MeetingSchema, meeting.id).status end) == "confirmed"
  end

  # The expiry released the slot, so a late completion bringing the booking
  # back competes with any new booking for it, and must count the slot under
  # the same organiser schedule lock that booking takes.
  test "a late completion and a new booking of an overlapping slot: one ends up live", ctx do
    {meeting, payment} = expired_booking(ctx.user, "cs_RACE_LATE")

    Mox.stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
      {:ok, %{"latest_charge" => "ch_RACE_LATE"}}
    end)

    results =
      race([
        fn hold ->
          RaceConductor.arm(hold, update_of("meetings"))
          complete(nil, "evt_RACE_LATE", meeting, "cs_RACE_LATE")
        end,
        fn hold ->
          RaceConductor.arm(hold, RaceConductor.insert_into("meetings"))

          Scheduling.create_meeting_with_conflict_check(
            booking_attrs(ctx.user, DateTime.add(meeting.start_time, 30, :minute))
          )
        end
      ])

    [completion, booking] = results
    assert completion == :ok
    assert live_meetings(ctx.user) == 1

    paid = unboxed(fn -> Repo.get!(BookingPaymentSchema, payment.id) end)
    assert paid.status == "paid"

    case booking do
      {:ok, %MeetingSchema{}} ->
        assert unboxed(fn -> Repo.get!(MeetingSchema, meeting.id).status end) == "expired"
        assert refunds_scheduled(payment) == 1

      {:error, :time_conflict} ->
        assert unboxed(fn -> Repo.get!(MeetingSchema, meeting.id).status end) == "confirmed"
        assert refunds_scheduled(payment) == 0
    end
  end

  defp complete(hold, event_id, meeting, session_id \\ "cs_RACE_DOUBLE") do
    # Parks holding the payment row it has just written, before committing.
    if hold, do: RaceConductor.arm(hold, update_of("booking_payments"))

    CheckoutSessionCompleted.handle(%{
      "id" => event_id,
      "account" => @account,
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "id" => session_id,
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_RACE_DOUBLE",
          "payment_status" => "paid",
          "amount_total" => 5000,
          "currency" => "eur"
        }
      }
    })
  end

  defp awaiting_payment_booking(user, session_id) do
    unboxed(fn ->
      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      payment =
        insert(:booking_payment,
          meeting_id: meeting.id,
          host_user_id: user.id,
          stripe_account_id: @account,
          stripe_checkout_session_id: session_id
        )

      {meeting, payment}
    end)
  end

  defp expired_booking(user, session_id) do
    unboxed(fn ->
      meeting =
        insert(:meeting,
          status: "expired",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      payment =
        insert(:booking_payment,
          meeting_id: meeting.id,
          host_user_id: user.id,
          status: "failed",
          stripe_account_id: @account,
          stripe_checkout_session_id: session_id
        )

      {meeting, payment}
    end)
  end

  defp booking_attrs(user, start_time) do
    %{
      uid: UUID.generate(),
      title: "Race",
      start_time: start_time,
      end_time: DateTime.add(start_time, 60, :minute),
      duration: 60,
      status: "confirmed",
      organizer_user_id: user.id,
      organizer_name: "Organiser",
      organizer_email: user.email,
      attendee_name: "Attendee",
      attendee_email: "attendee-#{System.unique_integer([:positive])}@example.com",
      attendee_timezone: "Etc/UTC",
      attendee_locale: "en"
    }
  end

  defp refunds_scheduled(payment) do
    unboxed(fn ->
      Repo.aggregate(
        from(j in Oban.Job,
          where:
            j.worker == "Tymeslot.MeetingPayments.Workers.RefundLatePayment" and
              fragment("?->>'booking_payment_id'", j.args) == ^payment.id
        ),
        :count
      )
    end)
  end

  defp live_meetings(user) do
    unboxed(fn ->
      Repo.aggregate(
        from(m in MeetingSchema,
          where: m.organizer_user_id == ^user.id and m.status == "confirmed"
        ),
        :count
      )
    end)
  end

  defp charge_event(event_id, payment, object) do
    %{
      "id" => event_id,
      "account" => @account,
      "data" => %{"object" => Map.put_new(object, "id", payment.stripe_charge_id)}
    }
  end

  defp update_of(table),
    do: &(&1[:source] == table and String.starts_with?(&1[:query], "UPDATE"))

  defp read_of(table),
    do: &(&1[:source] == table and String.starts_with?(&1[:query], "SELECT"))
end
