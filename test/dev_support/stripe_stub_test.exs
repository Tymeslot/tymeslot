defmodule Tymeslot.StripeStubTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Stripe.Charges
  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Integrations.Stripe.Refunds
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeWebhookFixtures

  @moduletag :payments

  @opts [api_key: "sk_test"]

  test "a stub answers its operation and records the form" do
    StripeStub.stub(:create_refund, StripeFixtures.object("refund"))

    assert {:ok, %{"id" => "re_test1"}} =
             Refunds.create(
               %{charge: "ch_1", metadata: %{a: "b"}, expand: ["charge"]},
               @opts
             )

    assert [request] = StripeStub.requests(:create_refund)

    assert request.form == %{
             "charge" => "ch_1",
             "metadata" => %{"a" => "b"},
             "expand" => ["charge"]
           }

    assert request.operation == :create_refund
    assert request.method == :post
    assert request.path == "/v1/refunds"
    assert request.query == %{}
    assert request.headers["authorization"] == "Bearer sk_test"
  end

  test "a GET records its decoded query" do
    StripeStub.stub(:list_charges, StripeFixtures.list([StripeFixtures.object("charge")]))

    assert {:ok, %{"data" => [%{"id" => "ch_test1"}]}} =
             Charges.list(%{limit: 3, expand: ["data.refunds"]}, @opts)

    assert [%{method: :get, form: %{}, query: query}] = StripeStub.requests()
    assert query == %{"limit" => "3", "expand" => ["data.refunds"]}
  end

  test "expect responses are used in order before the stub" do
    StripeStub.expect(:retrieve_refund, StripeFixtures.object("refund", %{"amount" => 1}))
    StripeStub.expect(:retrieve_refund, StripeFixtures.object("refund", %{"amount" => 2}))
    StripeStub.stub(:retrieve_refund, StripeFixtures.object("refund", %{"amount" => 3}))

    amounts =
      for _call <- 1..3 do
        {:ok, refund} = Refunds.retrieve("re_test1", @opts)
        refund["amount"]
      end

    assert amounts == [1, 2, 3]
  end

  test "a function response receives the recorded request" do
    StripeStub.stub(:create_refund, fn request ->
      StripeFixtures.object("refund", %{"amount" => String.to_integer(request.form["amount"])})
    end)

    assert {:ok, %{"amount" => 450}} =
             Refunds.create(%{charge: "ch_test1", amount: 450}, @opts)
  end

  test "a status and body pair is sent as given" do
    StripeStub.stub(:retrieve_charge, {402, %{"error" => %{"type" => "card_error"}}})

    assert {:error, %Error{status: 402, type: "card_error"}} =
             Charges.retrieve("ch_test1", @opts)
  end

  test "an error fixture becomes a Stripe.Error" do
    StripeStub.stub(:retrieve_charge, {:error_fixture, "resource_missing"})

    assert {:error, %Error{code: "resource_missing", status: 404}} =
             Charges.retrieve("ch_test1", @opts)
  end

  # A GET is retried, up to three attempts in all; retry delays are zero in test.
  test "a transport error reaches the client" do
    StripeStub.expect(:retrieve_charge, 3, {:transport_error, :timeout})

    assert {:error, %Error{type: "api_connection_error", reason: :timeout}} =
             Charges.retrieve("ch_test1", @opts)

    assert length(StripeStub.requests(:retrieve_charge)) == 3
  end

  # A plain spawned process, not `Task.async`: a task carries its caller in
  # `$callers`, which `Req.Test` already follows, so it would pass without
  # `allow/1`.
  test "a request from another process works after allow/1" do
    StripeStub.stub(:retrieve_charge, StripeFixtures.object("charge"))
    test_pid = self()

    pid =
      spawn(fn ->
        receive do
          :go -> send(test_pid, {:result, Charges.retrieve("ch_test1", @opts)})
        end
      end)

    StripeStub.allow(pid)
    send(pid, :go)

    assert_receive {:result, {:ok, %{"id" => "ch_test1"}}}
  end

  test "an unexpected request fails the test" do
    StripeStub.stub(:retrieve_refund, StripeFixtures.object("refund"))

    assert {:error, %Error{status: 500, message: message}} =
             Refunds.create(%{charge: "ch_test1"}, @opts)

    assert message =~ "create_refund"
    assert message =~ "/v1/refunds"

    assert_raise ExUnit.AssertionError, ~r"create_refund POST /v1/refunds", &StripeStub.verify!/0
  end

  test "a GET with no stub is answered once, without retries" do
    StripeStub.stub(:create_refund, StripeFixtures.object("refund"))

    assert {:error, %Error{status: 500, message: message}} =
             Refunds.retrieve("re_test1", @opts)

    assert message =~ "retrieve_refund GET /v1/refunds/re_test1"
    assert length(StripeStub.requests(:retrieve_refund)) == 1

    assert_raise ExUnit.AssertionError, ~r"retrieve_refund GET", &StripeStub.verify!/0
  end

  test "an unmet expect fails the test" do
    StripeStub.expect(:create_refund, 2, StripeFixtures.object("refund"))

    assert {:ok, _refund} = Refunds.create(%{charge: "ch_test1"}, @opts)

    assert_raise ExUnit.AssertionError, ~r"create_refund: 1 expected", &StripeStub.verify!/0
  end

  test "verify! passes once every expected response was used" do
    StripeStub.expect(:create_refund, StripeFixtures.object("refund"))

    assert {:ok, _refund} = Refunds.create(%{charge: "ch_test1"}, @opts)
    assert StripeStub.verify!() == :ok
  end

  test "requests/0 and verify!/0 raise where no stub was installed" do
    assert_raise ArgumentError, ~r"no stub installed", &StripeStub.requests/0
    assert_raise ArgumentError, ~r"no stub installed", &StripeStub.verify!/0
  end

  test "a task started from the test reads the test's requests" do
    StripeStub.stub(:retrieve_charge, StripeFixtures.object("charge"))
    assert {:ok, _charge} = Charges.retrieve("ch_test1", @opts)

    assert [%{operation: :retrieve_charge}] =
             fn -> StripeStub.requests() end |> Task.async() |> Task.await()
  end

  test "a process outside the test's callers cannot read its requests" do
    StripeStub.stub(:retrieve_charge, StripeFixtures.object("charge"))
    test_pid = self()

    spawn(fn ->
      outcome =
        try do
          StripeStub.requests()
        rescue
          error in ArgumentError -> error.message
        end

      send(test_pid, {:outcome, outcome})
    end)

    assert_receive {:outcome, message}
    assert message =~ "no stub installed"
  end

  test "shared!/1 refuses an async module", context do
    assert_raise ArgumentError, ~r"async: false", fn -> StripeStub.shared!(context) end
  end

  test "connect_event carries the account" do
    body =
      StripeWebhookFixtures.connect_event(
        "charge.refunded",
        StripeFixtures.object("charge"),
        "acct_1"
      )

    assert %{
             "object" => "event",
             "type" => "charge.refunded",
             "account" => "acct_1",
             "api_version" => "2025-11-17.clover",
             "data" => %{"object" => %{"id" => "ch_test1"}}
           } = Jason.decode!(body)
  end
end

defmodule Tymeslot.StripeStubSharedTest do
  # async: false - shared mode hands this test's stub to every process on the
  # node, so no other test may use Req.Test for Stripe meanwhile.
  use ExUnit.Case, async: false

  alias Tymeslot.Integrations.Stripe.Charges
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  @moduletag :payments

  setup {StripeStub, :shared!}

  test "shared!/1 answers processes that were never allowed" do
    StripeStub.stub(:retrieve_charge, StripeFixtures.object("charge"))
    test_pid = self()

    spawn(fn -> send(test_pid, {:result, Charges.retrieve("ch_test1", api_key: "sk")}) end)

    assert_receive {:result, {:ok, %{"id" => "ch_test1"}}}
  end
end
