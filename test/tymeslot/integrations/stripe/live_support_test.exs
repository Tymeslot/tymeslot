defmodule Tymeslot.Integrations.Stripe.LiveSupportTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :unit

  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeLiveContract
  alias Tymeslot.StripeLiveFlow
  alias Tymeslot.StripeLiveReport

  describe "StripeLiveContract" do
    test "a fixture compared with itself has no drift and no new keys" do
      charge = StripeFixtures.object("charge_with_refunds")

      assert StripeLiveContract.compare(charge, charge) == %{drift: [], new_keys: []}
    end

    test "reports a key Stripe stopped sending as drift and a new one as informational" do
      fixture = StripeFixtures.object("refund")
      live = fixture |> Map.delete("status") |> Map.put("brand_new", 1)

      assert %{drift: ["status"], new_keys: ["brand_new"]} =
               StripeLiveContract.compare(fixture, live)
    end

    test "ignores the keys under metadata" do
      assert StripeLiveContract.key_paths(%{"metadata" => %{"a" => 1}, "id" => "x"}) == [
               "id",
               "metadata"
             ]
    end

    test "sanitising maps live ids to fixture ids, redacts secrets and rewrites emails" do
      fixture = %{"id" => "re_test1", "charge" => "ch_test1", "url" => "https://x"}

      live = %{
        "id" => "re_3Abc12345",
        "charge" => "ch_3Abc12345",
        "url" => "https://pay.example/secret",
        "receipt" => "https://dashboard/re_3Abc12345",
        "email" => "someone@real.example"
      }

      ids = StripeLiveContract.id_map(fixture, live)

      assert ids == %{"re_3Abc12345" => "re_test1", "ch_3Abc12345" => "ch_test1"}

      assert StripeLiveContract.sanitise(live, ids) == %{
               "id" => "re_test1",
               "charge" => "ch_test1",
               "url" => "redacted",
               "receipt" => "https://dashboard/re_test1",
               "email" => "customer@example.test"
             }
    end
  end

  describe "recording stability" do
    test "maps every object id at the same position, not only the listed prefixes" do
      fixture = %{
        "id" => "ch_test1",
        "price" => %{"id" => "price_1AbCdE2fG", "product" => "prod_Zz9Yy8Xx7"},
        "items" => [%{"id" => "si_Qq1Ww2Ee3"}],
        "last_error" => "card_declined",
        "balance_transaction" => "txn_1Mm2Nn3Oo"
      }

      live = %{
        "id" => "ch_3Live99",
        "price" => %{"id" => "price_9ZzLive88", "product" => "prod_Live77Abc"},
        "items" => [%{"id" => "si_Live55Def"}],
        "last_error" => "card_expired",
        "balance_transaction" => "txn_Live44Ghi"
      }

      assert StripeLiveContract.id_map(fixture, live) == %{
               "ch_3Live99" => "ch_test1",
               "price_9ZzLive88" => "price_1AbCdE2fG",
               "prod_Live77Abc" => "prod_Zz9Yy8Xx7",
               "si_Live55Def" => "si_Qq1Ww2Ee3",
               "txn_Live44Ghi" => "txn_1Mm2Nn3Oo"
             }
    end

    test "the README update replaces only the provenance text" do
      readme = """
      | `customer.json` | API reference example (`customers/object`), fetched 2026-11-22 |
      | `checkout_session_payment.json` | API reference example (`checkout/sessions/object`), fetched 2026-11-22, unchanged: an open session has `payment_intent: null` |
      | `refund.json` | API reference example (`refunds/object`), fetched 2026-11-22 |
      """

      updated =
        StripeLiveContract.mark_recorded(
          readme,
          ["customer", "checkout_session_payment"],
          "2027-01-02"
        )

      assert updated =~ "| `customer.json` | recorded 2027-01-02 |"

      assert updated =~
               "| `checkout_session_payment.json` | recorded 2027-01-02, unchanged: an open session has `payment_intent: null` |"

      assert updated =~
               "| `refund.json` | API reference example (`refunds/object`), fetched 2026-11-22 |"
    end

    test "each fixture has exactly one designated recording step" do
      labels = [
        "Charges.retrieve",
        "Charges.retrieve (connect)",
        "Refunds.create",
        "Refunds.create (connect)"
      ]

      recorders = Enum.map(labels, &StripeLiveContract.recorded_by?/1)

      assert recorders == [true, false, true, false]
    end
  end

  describe "token links and labels" do
    test "recording redacts Stripe-hosted links under url and pdf keys" do
      live = %{
        "receipt_url" => "https://pay.stripe.com/receipts/payment/CAcaFw",
        "invoice_pdf" => "https://pay.stripe.com/invoice/acct_1/test_x/pdf",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/acct_1/test_x",
        "manage_url" => "https://billing.stripe.com/p/session/test_x",
        "return_url" => "https://example.test/back"
      }

      assert StripeLiveContract.sanitise(live, %{}) == %{
               "receipt_url" => "redacted",
               "invoice_pdf" => "redacted",
               "hosted_invoice_url" => "redacted",
               "manage_url" => "redacted",
               "return_url" => "https://example.test/back"
             }
    end

    test "every recording step label is used by exactly one step in the suite" do
      suite = File.read!(Path.expand("live_test.exs", __DIR__))

      counts =
        for label <- StripeLiveContract.recorded_labels() do
          pattern = ~r/step\(\s*flow,\s*#{Regex.escape(inspect(label))}/
          {label, length(Regex.scan(pattern, suite))}
        end

      assert Enum.reject(counts, fn {_label, count} -> count == 1 end) == []
    end
  end

  describe "StripeLiveFlow" do
    setup do
      report = StripeLiveReport.start()
      on_exit(fn -> Agent.stop(report) end)
      {:ok, report: report, flow: StripeLiveFlow.new(report, "flow", live?: true, record?: false)}
    end

    test "records every step and fails at the end, skipping dependants of a failure", %{
      flow: flow,
      report: report
    } do
      error = %Error{
        type: "invalid_request_error",
        code: "x",
        status: 400,
        message: "bad sk_test_abc123"
      }

      first = StripeLiveFlow.step(flow, "first", fn -> {:error, error} end)
      StripeLiveFlow.step(flow, "second", [needs: [{"first", first}]], fn -> {:ok, %{}} end)
      StripeLiveFlow.step(flow, "third", fn -> {:ok, %{}} end)

      assert [
               %{
                 operation: "first",
                 status: :failed,
                 error: %{code: "x", message: "bad [redacted key]"}
               },
               %{operation: "second", status: :skipped, note: "depends on first"},
               %{operation: "third", status: :ok}
             ] = StripeLiveReport.steps(report)

      assert StripeLiveFlow.failed_steps(flow) == ["first"]
    end

    test "a missing fixture key fails the step with the drifted path", %{
      flow: flow,
      report: report
    } do
      live = "refund" |> StripeFixtures.object() |> Map.delete("status")

      StripeLiveFlow.step(flow, "Refunds.retrieve", fn -> {:ok, live} end)

      assert [%{status: :failed, drift: ["status"]}] = StripeLiveReport.steps(report)
    end

    test "recording captures only the designated step", %{report: report} do
      flow = StripeLiveFlow.new(report, "rec", live?: true, record?: true)
      charge = StripeFixtures.object("charge")

      StripeLiveFlow.step(flow, "Charges.retrieve (connect)", fn -> {:ok, charge} end)
      StripeLiveFlow.step(flow, "Charges.retrieve", fn -> {:ok, charge} end)

      assert [{"charge", _live}] = Agent.get(report, & &1.captures)
    end

    test "a skip pattern never hides an error that names a param", %{flow: flow, report: report} do
      by_message = %Error{type: "invalid_request_error", message: "Set your tax settings first"}
      by_param = %Error{by_message | param: "automatic_tax"}

      assert {:skip, "Set your tax settings first"} =
               StripeLiveFlow.skip_if({:error, by_message}, ~r/tax settings/)

      assert {:error, ^by_param} = StripeLiveFlow.skip_if({:error, by_param}, ~r/tax settings/)

      StripeLiveFlow.step(flow, "bad param", fn -> {:error, by_param} end)

      assert [%{error: %{param: "automatic_tax", decline_code: nil}}] =
               StripeLiveReport.steps(report)
    end

    test "without a key every step is skipped and the function never runs", %{report: report} do
      flow = StripeLiveFlow.new(report, "keyless", live?: false, record?: false)

      assert {:skip, "STRIPE_TEST_SECRET_KEY not set"} =
               StripeLiveFlow.step(flow, "boom", fn -> raise "must not run" end)

      assert [%{status: :skipped}] = StripeLiveReport.steps(report)
    end
  end
end
