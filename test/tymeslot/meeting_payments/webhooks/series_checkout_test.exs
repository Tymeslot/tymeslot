defmodule Tymeslot.MeetingPayments.Webhooks.SeriesCheckoutTest do
  @moduledoc """
  The Connect events of a paid series' one payment: found by its
  `series:<id>` reference or its PaymentIntent metadata, only from the
  account it was charged on, applied once however often Stripe (or the
  reconciliation sweep) delivers them.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.PaidSeriesTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.CalendarMock
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.SeriesAnnouncementWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    host = paid_host()
    expect_checkout()
    assert {:ok, :payment_required, %{series: series}} = book(host, paid_series_type(host), 3)

    %{series: series, payment: MeetingPayments.payment_for_series(series.id)}
  end

  defp statuses,
    do:
      Repo.all(
        from(m in MeetingSchema,
          where: not is_nil(m.series_id),
          order_by: m.series_position,
          select: m.status
        )
      )

  defp total, do: 3 * price_cents()

  # A row whose Stripe ids were never attached (the attach failed, or a
  # charge event raced ahead of it).
  defp detach(payment) do
    payment
    |> Changeset.change(stripe_checkout_session_id: nil, stripe_payment_intent_id: nil)
    |> Repo.update!()
  end

  test "a session event finds the payment by its series reference", %{
    series: series,
    payment: payment
  } do
    detach(payment)
    event = completed_event("evt_REF", series.id, total(), %{"id" => "cs_NOT_ATTACHED"})

    assert PaymentLookup.find_for_session(event).id == payment.id

    # A meeting id where the series reference belongs finds nothing.
    [first | _rest] = Repo.all(from(m in MeetingSchema, where: m.series_id == ^series.id))
    by_meeting = put_in(event, ["data", "object", "client_reference_id"], first.id)
    assert PaymentLookup.find_for_session(by_meeting) == nil
  end

  test "a charge event finds the payment by the series in its metadata", %{
    series: series,
    payment: payment
  } do
    detach(payment)

    expect(StripeAdapterMock, :retrieve_payment_intent, fn "pi_RACE", opts ->
      assert opts[:connect_account] == account()
      {:ok, %{metadata: %{"series_id" => series.id}}}
    end)

    event = %{
      "id" => "evt_CHARGE",
      "account" => account(),
      "data" => %{"object" => %{"payment_intent" => "pi_RACE"}}
    }

    assert PaymentLookup.find_for_charge(event, "ch_UNLINKED").id == payment.id
  end

  test "an event from another account is ignored", %{series: series, payment: payment} do
    event =
      "evt_FOREIGN"
      |> completed_event(series.id, total())
      |> Map.put("account", "acct_SOMEONE_ELSE")

    assert PaymentLookup.find_for_session(event) == nil
    assert :ok = CheckoutSessionCompleted.handle(event)

    assert Repo.reload!(payment).status == :pending
    assert statuses() == [:awaiting_payment, :awaiting_payment, :awaiting_payment]
  end

  test "the same event delivered twice confirms the series once", %{
    series: series,
    payment: payment
  } do
    event = completed_event("evt_TWICE", series.id, total())

    assert :ok = CheckoutSessionCompleted.handle(event)
    assert :ok = CheckoutSessionCompleted.handle(event)

    assert statuses() == [:confirmed, :confirmed, :confirmed]
    assert %{status: :paid, last_event_id: "evt_TWICE"} = Repo.reload!(payment)
    assert length(all_enqueued(worker: CalendarEventWorker, args: %{"action" => "create"})) == 3
    assert [_one] = all_enqueued(worker: SeriesAnnouncementWorker)
  end

  test "a completion for a different amount is not the series' payment", %{
    series: series,
    payment: payment
  } do
    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_ONE", series.id, 5_000))

    assert Repo.reload!(payment).status == :pending
    assert statuses() == [:awaiting_payment, :awaiting_payment, :awaiting_payment]
  end

  test "the reconciliation sweep replays a stale series payment", %{
    series: series,
    payment: payment
  } do
    stale = DateTime.add(DateTime.utc_now(:second), -2, :hour)
    payment |> Changeset.change(inserted_at: stale) |> Repo.update!()

    expect(StripeAdapterMock, :retrieve_checkout_session, fn id, opts ->
      assert id == session_id()
      assert opts[:connect_account] == account()
      {:ok, completed_event("unused", series.id, total())["data"]["object"]}
    end)

    assert {:ok, %{reconciled: 1}} = perform_job(ReconcileAwaitingPayments, %{})

    assert statuses() == [:confirmed, :confirmed, :confirmed]
    assert Repo.reload!(payment).status == :paid
  end
end
