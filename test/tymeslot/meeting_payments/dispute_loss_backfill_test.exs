defmodule Tymeslot.MeetingPayments.DisputeLossBackfillTest do
  use Tymeslot.DataCase, async: true

  @moduletag :payments
  @moduletag :database

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.DisputeLossBackfill
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  defp refunded_payment(attrs) do
    insert(
      :paid_booking_payment,
      Keyword.merge(
        [amount_cents: 10_000, refunded_amount_cents: 10_000, status: :refunded],
        attrs
      )
    )
  end

  defp disputes(charge_id, disputes) do
    disputes
    |> Enum.map(fn {status, amount} ->
      StripeFixtures.object("dispute_lost", %{
        "charge" => charge_id,
        "status" => status,
        "amount" => amount
      })
    end)
    |> StripeFixtures.list(url: "/v1/disputes")
  end

  defp lost_cents_of(payment), do: Repo.get!(BookingPaymentSchema, payment.id).disputed_lost_cents

  defp run!(opts), do: DisputeLossBackfill.run(Keyword.put(opts, :pause_ms, 0))

  test "a lost dispute is recorded from Stripe" do
    payment =
      refunded_payment(stripe_charge_id: "ch_1", stripe_account_id: "acct_backfill")

    StripeStub.expect(:list_disputes, disputes("ch_1", [{"lost", 6_000}]))

    assert %{candidates: 1, lost: 1, updated: 1, clamped: 0, unchanged: 0, errors: []} =
             run!(dry_run: false)

    assert lost_cents_of(payment) == 6_000

    reloaded = Repo.get!(BookingPaymentSchema, payment.id)
    assert reloaded.refunded_amount_cents == 10_000
    assert reloaded.status == :refunded

    assert [request] = StripeStub.requests(:list_disputes)
    assert request.query["charge"] == "ch_1"
    assert request.headers["stripe-account"] == "acct_backfill"
  end

  test "a won dispute changes nothing" do
    payment = refunded_payment(stripe_charge_id: "ch_won")
    StripeStub.expect(:list_disputes, disputes("ch_won", [{"won", 6_000}]))

    assert %{candidates: 1, lost: 0, updated: 0} = run!(dry_run: false)
    assert lost_cents_of(payment) == 0
  end

  test "the loss is clamped to what was refunded" do
    payment =
      refunded_payment(
        stripe_charge_id: "ch_clamp",
        refunded_amount_cents: 5_000,
        status: :partially_refunded
      )

    StripeStub.expect(:list_disputes, disputes("ch_clamp", [{"lost", 6_000}]))

    assert %{updated: 1, clamped: 1, errors: []} = run!(dry_run: false)

    reloaded = Repo.get!(BookingPaymentSchema, payment.id)
    assert reloaded.disputed_lost_cents == 5_000
    assert reloaded.disputed_lost_cents <= reloaded.refunded_amount_cents
  end

  test "a dry run writes nothing" do
    payment = refunded_payment(stripe_charge_id: "ch_dry")
    StripeStub.expect(:list_disputes, disputes("ch_dry", [{"lost", 6_000}]))

    assert %{candidates: 1, lost: 1, updated: 0, errors: []} =
             DisputeLossBackfill.run(pause_ms: 0)

    assert lost_cents_of(payment) == 0
  end

  test "a second run is a no-op" do
    payment = refunded_payment(stripe_charge_id: "ch_twice")
    StripeStub.expect(:list_disputes, disputes("ch_twice", [{"lost", 6_000}]))

    assert %{updated: 1} = run!(dry_run: false)
    assert %{candidates: 0, updated: 0} = run!(dry_run: false)

    assert lost_cents_of(payment) == 6_000
    assert [_only] = StripeStub.requests(:list_disputes)
  end

  test "a loss recorded while Stripe answers is left as it is" do
    payment = refunded_payment(stripe_charge_id: "ch_race")

    StripeStub.expect(:list_disputes, fn _request ->
      # A dispute webhook records the loss between the read and the write.
      Repo.update_all(from(b in BookingPaymentSchema, where: b.id == ^payment.id),
        set: [disputed_lost_cents: 3_000]
      )

      disputes("ch_race", [{"lost", 6_000}])
    end)

    assert %{lost: 1, updated: 0, unchanged: 1, errors: []} = run!(dry_run: false)
    assert lost_cents_of(payment) == 3_000
  end

  test "a Stripe failure is reported and the run continues" do
    [first, second] =
      Enum.sort_by(
        [
          refunded_payment(stripe_charge_id: "ch_a"),
          refunded_payment(stripe_charge_id: "ch_b")
        ],
        & &1.id
      )

    StripeStub.stub(:list_disputes, fn request ->
      if request.query["charge"] == first.stripe_charge_id,
        do: {:error_fixture, "api_error"},
        else: disputes(second.stripe_charge_id, [{"lost", 2_000}])
    end)

    assert %{candidates: 2, updated: 1, errors: [{failed_id, _reason}]} = run!(dry_run: false)
    assert failed_id == first.id
    assert lost_cents_of(first) == 0
    assert lost_cents_of(second) == 2_000
  end

  test "rows outside the candidate set are never read" do
    already = insert(:paid_booking_payment, stripe_charge_id: "ch_done", amount_cents: 10_000)

    Repo.update_all(
      from(b in BookingPaymentSchema, where: b.id == ^already.id),
      set: [refunded_amount_cents: 6_000, disputed_lost_cents: 6_000, status: :refunded]
    )

    refunded_payment(stripe_charge_id: nil)
    refunded_payment(stripe_charge_id: "ch_open", status: :disputed)

    assert %{candidates: 0} = run!(dry_run: false)
    assert StripeStub.requests(:list_disputes) == []
  end

  test "limit caps how many candidates are read" do
    refunded_payment(stripe_charge_id: "ch_l1")
    refunded_payment(stripe_charge_id: "ch_l2")
    StripeStub.stub(:list_disputes, StripeFixtures.list([], url: "/v1/disputes"))

    assert %{candidates: 1} = run!(limit: 1)
    assert [_one] = StripeStub.requests(:list_disputes)
  end

  describe "lost_cents/2" do
    @describetag :unit

    defp dispute(status, amount), do: %{"status" => status, "amount" => amount}

    test "a lost dispute is the amount it took" do
      assert DisputeLossBackfill.lost_cents([dispute("lost", 3_000)], %{
               refunded_amount_cents: 10_000
             }) == {:lost, 3_000}
    end

    test "won and warning_closed disputes take nothing" do
      payment = %{refunded_amount_cents: 10_000}
      assert DisputeLossBackfill.lost_cents([dispute("won", 3_000)], payment) == :none
      assert DisputeLossBackfill.lost_cents([dispute("warning_closed", 3_000)], payment) == :none
      assert DisputeLossBackfill.lost_cents([], payment) == :none
    end

    test "only the lost disputes of a mixed list are summed" do
      disputes = [dispute("warning_closed", 1_000), dispute("lost", 2_500), dispute("lost", 500)]

      assert DisputeLossBackfill.lost_cents(disputes, %{refunded_amount_cents: 10_000}) ==
               {:lost, 3_000}
    end

    test "a loss larger than what was refunded is clamped to it" do
      assert DisputeLossBackfill.lost_cents([dispute("lost", 6_000)], %{
               refunded_amount_cents: 5_000
             }) == {:clamped, 5_000}
    end
  end
end
