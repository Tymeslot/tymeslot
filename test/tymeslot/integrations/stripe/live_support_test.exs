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
        "id" => "re_3Abc",
        "charge" => "ch_3Abc",
        "url" => "https://pay.example/secret",
        "receipt" => "https://dashboard/re_3Abc",
        "email" => "someone@real.example"
      }

      ids = StripeLiveContract.id_map(fixture, live)

      assert ids == %{"re_3Abc" => "re_test1", "ch_3Abc" => "ch_test1"}

      assert StripeLiveContract.sanitise(live, ids) == %{
               "id" => "re_test1",
               "charge" => "ch_test1",
               "url" => "redacted",
               "receipt" => "https://dashboard/re_test1",
               "email" => "customer@example.test"
             }
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

    test "without a key every step is skipped and the function never runs", %{report: report} do
      flow = StripeLiveFlow.new(report, "keyless", live?: false, record?: false)

      assert {:skip, "STRIPE_TEST_SECRET_KEY not set"} =
               StripeLiveFlow.step(flow, "boom", fn -> raise "must not run" end)

      assert [%{status: :skipped}] = StripeLiveReport.steps(report)
    end
  end
end
