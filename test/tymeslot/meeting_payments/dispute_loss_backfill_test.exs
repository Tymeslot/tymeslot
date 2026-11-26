defmodule Tymeslot.MeetingPayments.DisputeLossBackfillTest do
  use Tymeslot.DataCase, async: true

  @moduletag :payments
  @moduletag :database

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.DisputeLossBackfill
  alias Tymeslot.MeetingPayments.RefundedTotal
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  # Created before this test database ran its migrations, as a payment
  # whose figures the backfill may correct was.
  defp refunded_payment(attrs) do
    insert(
      :paid_booking_payment,
      Keyword.merge(
        [
          amount_cents: 10_000,
          refunded_amount_cents: 10_000,
          status: :refunded,
          inserted_at: ~U[2026-01-01 00:00:00Z]
        ],
        attrs
      )
    )
  end

  # Dates the migration `version` as having run on this deployment `at`.
  defp migrated(version, at) do
    assert %{num_rows: 1} =
             Repo.query!("UPDATE schema_migrations SET inserted_at = $1 WHERE version = $2", [
               DateTime.to_naive(at),
               version
             ])
  end

  defp disputes_read,
    do: Enum.map(StripeStub.requests(:list_disputes), & &1.query["charge"])

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

  defp charge(charge_id, amount_refunded) do
    StripeFixtures.object("charge", %{
      "id" => charge_id,
      "amount" => 10_000,
      "amount_refunded" => amount_refunded
    })
  end

  defp reload(payment), do: Repo.get!(BookingPaymentSchema, payment.id)

  defp run!(opts), do: DisputeLossBackfill.run(Keyword.put(opts, :pause_ms, 0))

  test "a lost dispute is recorded from Stripe" do
    payment =
      refunded_payment(stripe_charge_id: "ch_1", stripe_account_id: "acct_backfill")

    StripeStub.expect(:list_disputes, disputes("ch_1", [{"lost", 6_000}]))
    StripeStub.expect(:retrieve_charge, charge("ch_1", 0))

    assert %{candidates: 1, lost: 1, updated: 1, clamped: 0, unchanged: 0, errors: []} =
             run!(dry_run: false)

    reloaded = reload(payment)
    assert reloaded.disputed_lost_cents == 6_000
    assert reloaded.refunded_amount_cents == 10_000
    assert reloaded.status == :refunded

    assert [request] = StripeStub.requests(:list_disputes)
    assert request.query["charge"] == "ch_1"
    assert request.headers["stripe-account"] == "acct_backfill"

    assert [%{path: "/v1/charges/ch_1", headers: %{"stripe-account" => "acct_backfill"}}] =
             StripeStub.requests(:retrieve_charge)
  end

  test "a refund made before the loss is kept in the total" do
    # Stored by the older handlers as max(refunds, disputed), not their sum.
    payment =
      refunded_payment(
        stripe_charge_id: "ch_both",
        refunded_amount_cents: 4_000,
        status: :partially_refunded
      )

    StripeStub.expect(:list_disputes, disputes("ch_both", [{"lost", 3_000}]))
    StripeStub.expect(:retrieve_charge, charge("ch_both", 4_000))

    assert %{updated: 1, clamped: 0} = run!(dry_run: false)

    reloaded = reload(payment)
    assert reloaded.disputed_lost_cents == 3_000
    assert reloaded.refunded_amount_cents == 7_000
    assert reloaded.status == :partially_refunded
    assert RefundedTotal.stripe_refunded_cents(reloaded) == 4_000
    assert RefundedTotal.refundable_cents(reloaded, 0) == 3_000
  end

  test "the whole is never lowered" do
    payment =
      refunded_payment(
        stripe_charge_id: "ch_keep",
        refunded_amount_cents: 9_000,
        status: :partially_refunded
      )

    StripeStub.expect(:list_disputes, disputes("ch_keep", [{"lost", 3_000}]))
    StripeStub.expect(:retrieve_charge, charge("ch_keep", 2_000))

    assert %{updated: 1} = run!(dry_run: false)

    reloaded = reload(payment)
    assert reloaded.refunded_amount_cents == 9_000
    assert reloaded.disputed_lost_cents == 3_000
    assert reloaded.stripe_refunded_cents == 6_000
    assert reloaded.status == :partially_refunded
  end

  test "refunds a recorded loss hid under the amount paid are read from the charge" do
    # Refunded in full, then lost in a dispute over the same money, and
    # recorded before the refunds had a column of their own: filled as the
    # whole less the loss, which the cap left at nothing.
    payment =
      refunded_payment(
        stripe_charge_id: "ch_hidden",
        stripe_refunded_cents: 0,
        disputed_lost_cents: 10_000
      )

    StripeStub.expect(:list_disputes, disputes("ch_hidden", [{"lost", 10_000}]))
    StripeStub.expect(:retrieve_charge, charge("ch_hidden", 10_000))

    assert %{candidates: 1, lost: 1, updated: 1, clamped: 0, errors: []} = run!(dry_run: false)

    reloaded = reload(payment)
    assert reloaded.stripe_refunded_cents == 10_000
    assert reloaded.disputed_lost_cents == 10_000
    assert reloaded.refunded_amount_cents == 10_000
    assert reloaded.status == :refunded
  end

  test "a recorded loss whose refunds Stripe confirms is left as it is" do
    payment =
      refunded_payment(
        stripe_charge_id: "ch_agrees",
        stripe_refunded_cents: 4_000,
        disputed_lost_cents: 6_000
      )

    StripeStub.expect(:list_disputes, disputes("ch_agrees", [{"lost", 6_000}]))
    StripeStub.expect(:retrieve_charge, charge("ch_agrees", 4_000))

    assert %{candidates: 1, lost: 0, updated: 0, unchanged: 0, errors: []} =
             run!(dry_run: false)

    reloaded = reload(payment)
    assert reloaded.stripe_refunded_cents == 4_000
    assert reloaded.disputed_lost_cents == 6_000
    assert reloaded.refunded_amount_cents == 10_000
  end

  test "a won dispute changes nothing" do
    payment = refunded_payment(stripe_charge_id: "ch_won")
    StripeStub.expect(:list_disputes, disputes("ch_won", [{"won", 6_000}]))

    assert %{candidates: 1, lost: 0, updated: 0} = run!(dry_run: false)
    assert reload(payment).disputed_lost_cents == 0
    assert StripeStub.requests(:retrieve_charge) == []
  end

  test "the loss is clamped to the amount paid" do
    payment =
      refunded_payment(
        stripe_charge_id: "ch_clamp",
        amount_cents: 5_000,
        refunded_amount_cents: 3_000,
        status: :partially_refunded
      )

    StripeStub.expect(:list_disputes, disputes("ch_clamp", [{"lost", 3_000}, {"lost", 3_000}]))
    StripeStub.expect(:retrieve_charge, charge("ch_clamp", 0))

    assert %{updated: 1, clamped: 1, errors: []} = run!(dry_run: false)

    reloaded = reload(payment)
    assert reloaded.disputed_lost_cents == 5_000
    assert reloaded.refunded_amount_cents == 5_000
    assert reloaded.status == :refunded
  end

  test "a dry run writes nothing" do
    payment = refunded_payment(stripe_charge_id: "ch_dry", refunded_amount_cents: 4_000)
    StripeStub.expect(:list_disputes, disputes("ch_dry", [{"lost", 3_000}]))
    StripeStub.expect(:retrieve_charge, charge("ch_dry", 4_000))

    assert %{candidates: 1, lost: 1, updated: 0, errors: []} =
             DisputeLossBackfill.run(pause_ms: 0)

    reloaded = reload(payment)
    assert reloaded.disputed_lost_cents == 0
    assert reloaded.refunded_amount_cents == 4_000
  end

  test "a second run is a no-op" do
    payment =
      refunded_payment(
        stripe_charge_id: "ch_twice",
        refunded_amount_cents: 6_000,
        status: :partially_refunded
      )

    StripeStub.expect(:list_disputes, disputes("ch_twice", [{"lost", 6_000}]))
    StripeStub.expect(:retrieve_charge, charge("ch_twice", 0))

    assert %{updated: 1} = run!(dry_run: false)
    assert %{candidates: 0, updated: 0} = run!(dry_run: false)

    assert reload(payment).disputed_lost_cents == 6_000
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

    StripeStub.expect(:retrieve_charge, charge("ch_race", 0))

    assert %{lost: 1, updated: 0, unchanged: 1, errors: []} = run!(dry_run: false)
    assert reload(payment).disputed_lost_cents == 3_000
  end

  test "a total changed while Stripe answers is left as it is" do
    payment =
      refunded_payment(
        stripe_charge_id: "ch_total",
        refunded_amount_cents: 4_000,
        status: :partially_refunded
      )

    StripeStub.expect(:list_disputes, disputes("ch_total", [{"lost", 3_000}]))

    StripeStub.expect(:retrieve_charge, fn _request ->
      # A refund webhook records a refund between the read and the write.
      Repo.update_all(from(b in BookingPaymentSchema, where: b.id == ^payment.id),
        set: [refunded_amount_cents: 5_000]
      )

      charge("ch_total", 5_000)
    end)

    assert %{lost: 1, updated: 0, unchanged: 1} = run!(dry_run: false)

    reloaded = reload(payment)
    assert reloaded.refunded_amount_cents == 5_000
    assert reloaded.disputed_lost_cents == 0
  end

  test "a status changed while Stripe answers is left as it is" do
    payment = refunded_payment(stripe_charge_id: "ch_status")

    StripeStub.expect(:list_disputes, disputes("ch_status", [{"lost", 3_000}]))

    StripeStub.expect(:retrieve_charge, fn _request ->
      # A dispute webhook opens a new dispute between the read and the write.
      Repo.update_all(from(b in BookingPaymentSchema, where: b.id == ^payment.id),
        set: [status: :disputed]
      )

      charge("ch_status", 0)
    end)

    assert %{lost: 1, updated: 0, unchanged: 1} = run!(dry_run: false)

    reloaded = reload(payment)
    assert reloaded.status == :disputed
    assert reloaded.disputed_lost_cents == 0
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

    StripeStub.expect(:retrieve_charge, charge(second.stripe_charge_id, 0))

    assert %{candidates: 2, updated: 1, errors: [{failed_id, _reason}]} = run!(dry_run: false)
    assert failed_id == first.id
    assert reload(first).disputed_lost_cents == 0
    assert reload(second).disputed_lost_cents == 2_000
  end

  test "a failed charge read is reported for that payment" do
    payment = refunded_payment(stripe_charge_id: "ch_gone")
    StripeStub.expect(:list_disputes, disputes("ch_gone", [{"lost", 2_000}]))
    StripeStub.expect(:retrieve_charge, {:error_fixture, "resource_missing"})

    assert %{lost: 0, updated: 0, errors: [{failed_id, _reason}]} = run!(dry_run: false)
    assert failed_id == payment.id
    assert reload(payment).disputed_lost_cents == 0
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

  describe "how far back the candidates go" do
    # The deployment tracked disputes on the payment from March, kept
    # losses apart from June and the refunds made apart from September.
    setup do
      migrated(20_261_103_142_458, ~U[2026-03-01 00:00:00Z])
      migrated(20_261_120_141_652, ~U[2026-06-01 00:00:00Z])
      migrated(20_261_124_084_318, ~U[2026-09-01 00:00:00Z])
      StripeStub.stub(:list_disputes, StripeFixtures.list([], url: "/v1/disputes"))
      :ok
    end

    test "a refunded payment created once losses were kept apart is never read" do
      refunded_payment(
        stripe_charge_id: "ch_new",
        stripe_dispute_id: "dp_new",
        inserted_at: ~U[2026-07-01 00:00:00Z]
      )

      assert %{candidates: 0} = run!([])
      assert disputes_read() == []
    end

    test "one created while disputes were tracked is read only if it saw one" do
      refunded_payment(stripe_charge_id: "ch_plain", inserted_at: ~U[2026-04-01 00:00:00Z])

      refunded_payment(
        stripe_charge_id: "ch_disputed",
        stripe_dispute_id: "dp_1",
        inserted_at: ~U[2026-04-01 00:00:00Z]
      )

      assert %{candidates: 1} = run!([])
      assert disputes_read() == ["ch_disputed"]
    end

    test "one created before disputes were tracked is read without a dispute on it" do
      refunded_payment(stripe_charge_id: "ch_old", inserted_at: ~U[2026-02-01 00:00:00Z])

      assert %{candidates: 1} = run!([])
      assert disputes_read() == ["ch_old"]
    end

    test "a recorded loss is read only on a payment created before refunds were kept apart" do
      for {charge, inserted_at} <- [
            {"ch_hid", ~U[2026-08-01 00:00:00Z]},
            {"ch_recent", ~U[2026-10-01 00:00:00Z]}
          ] do
        refunded_payment(
          stripe_charge_id: charge,
          stripe_refunded_cents: 0,
          disputed_lost_cents: 10_000,
          stripe_dispute_id: "dp_" <> charge,
          inserted_at: inserted_at
        )
      end

      assert %{candidates: 1} = run!([])
      assert disputes_read() == ["ch_hid"]
    end
  end

  test "limit caps how many candidates are read" do
    refunded_payment(stripe_charge_id: "ch_l1")
    refunded_payment(stripe_charge_id: "ch_l2")
    StripeStub.stub(:list_disputes, StripeFixtures.list([], url: "/v1/disputes"))

    assert %{candidates: 1} = run!(limit: 1)
    assert [_one] = StripeStub.requests(:list_disputes)
  end

  describe "lost_total/1" do
    @describetag :unit

    defp dispute(status, amount), do: %{"status" => status, "amount" => amount}

    test "won and warning_closed disputes take nothing" do
      assert DisputeLossBackfill.lost_total([dispute("won", 3_000)]) == 0
      assert DisputeLossBackfill.lost_total([dispute("warning_closed", 3_000)]) == 0
      assert DisputeLossBackfill.lost_total([]) == 0
    end

    test "only the lost disputes of a mixed list are summed" do
      disputes = [dispute("warning_closed", 1_000), dispute("lost", 2_500), dispute("lost", 500)]
      assert DisputeLossBackfill.lost_total(disputes) == 3_000
    end
  end

  describe "correction/3" do
    @describetag :unit

    # A row from before `disputed_lost_cents`: the loss is counted as refunds.
    defp payment(refunded, amount \\ 10_000),
      do: %BookingPaymentSchema{
        amount_cents: amount,
        refunded_amount_cents: refunded,
        stripe_refunded_cents: refunded,
        disputed_lost_cents: 0,
        status: :partially_refunded
      }

    defp stripe_charge(refunded), do: %{"amount_refunded" => refunded}

    test "a loss alone keeps the total and takes its share of it" do
      assert DisputeLossBackfill.correction(payment(6_000), 6_000, stripe_charge(0)) ==
               {:lost,
                %{
                  stripe_refunded_cents: 0,
                  disputed_lost_cents: 6_000,
                  refunded_amount_cents: 6_000,
                  status: :partially_refunded
                }}
    end

    test "refunds made before the loss are added to it" do
      assert DisputeLossBackfill.correction(payment(4_000), 3_000, stripe_charge(4_000)) ==
               {:lost,
                %{
                  stripe_refunded_cents: 4_000,
                  disputed_lost_cents: 3_000,
                  refunded_amount_cents: 7_000,
                  status: :partially_refunded
                }}
    end

    test "the total never falls below the one held" do
      assert {:lost, %{refunded_amount_cents: 9_000, disputed_lost_cents: 3_000}} =
               DisputeLossBackfill.correction(payment(9_000), 3_000, stripe_charge(2_000))
    end

    test "refunds and loss together stop at the amount paid" do
      assert {:lost,
              %{disputed_lost_cents: 6_000, refunded_amount_cents: 10_000, status: :refunded}} =
               DisputeLossBackfill.correction(payment(6_000), 6_000, stripe_charge(10_000))
    end

    test "a loss larger than the amount paid is clamped to it" do
      assert DisputeLossBackfill.correction(payment(3_000, 5_000), 6_000, stripe_charge(0)) ==
               {:clamped,
                %{
                  stripe_refunded_cents: 0,
                  disputed_lost_cents: 5_000,
                  refunded_amount_cents: 5_000,
                  status: :refunded
                }}
    end

    test "a recorded loss gets the refunds the cap hid from the charge" do
      recorded = %{payment(10_000) | stripe_refunded_cents: 0, disputed_lost_cents: 10_000}

      assert DisputeLossBackfill.correction(recorded, 10_000, stripe_charge(10_000)) ==
               {:lost,
                %{
                  stripe_refunded_cents: 10_000,
                  disputed_lost_cents: 10_000,
                  refunded_amount_cents: 10_000,
                  status: :refunded
                }}
    end

    test "the share always fits the check constraint and the total is never lowered" do
      amount = 10_000
      steps = [1, 2_500, 5_000, 9_999, 10_000]

      cases =
        for stored <- steps,
            stripe_refunded <- [0 | steps],
            lost <- steps ++ [15_000],
            do: {stored, stripe_refunded, lost}

      assert length(cases) == 180

      violations =
        Enum.reject(cases, fn {stored, stripe_refunded, lost} ->
          {_kind, c} =
            DisputeLossBackfill.correction(
              payment(stored, amount),
              lost,
              stripe_charge(stripe_refunded)
            )

          c.disputed_lost_cents > 0 and c.disputed_lost_cents <= c.refunded_amount_cents and
            c.refunded_amount_cents <= amount and c.refunded_amount_cents >= stored and
            c.stripe_refunded_cents in 0..amount and
            c.refunded_amount_cents ==
              min(c.stripe_refunded_cents + c.disputed_lost_cents, amount)
        end)

      assert violations == []
    end
  end
end
