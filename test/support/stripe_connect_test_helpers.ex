defmodule Tymeslot.StripeConnectTestHelpers do
  @moduledoc """
  Shared steps for tests that connect a host's Stripe account through OAuth,
  with the Stripe API stubbed by `Tymeslot.StripeStub` and the OAuth token
  exchange by `Req.Test` (`:tymeslot_http`).
  """

  import ExUnit.Assertions, only: [assert: 1, flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  @routes_key {__MODULE__, :oauth_routes}

  @doc "Setup callback turning meeting payments on."
  @spec enable_meeting_payments(map()) :: :ok
  def enable_meeting_payments(_context) do
    with_config(:tymeslot,
      meeting_payments_enabled: true,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker
    )

    :ok
  end

  @doc "Starts onboarding for the user and returns the OAuth `state` value."
  @spec started_state(map()) :: String.t()
  def started_state(user) do
    {:ok, %{url: url}} = ConnectAccounts.start_onboarding(user)
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
  end

  @doc "Runs the whole OAuth callback for `stripe_account_id`, a French EUR account."
  @spec connect_account(map(), String.t()) :: :ok
  def connect_account(user, stripe_account_id) do
    state = started_state(user)
    code = "code_" <> stripe_account_id
    expect_exchange(code, stripe_account_id)
    expect_retrieve(stripe_account_id, %{"country" => "FR", "default_currency" => "eur"})

    assert {:ok, _account} = ConnectAccounts.complete_oauth_callback(user, code, state)
    :ok
  end

  @type exchange_outcome ::
          String.t()
          | {:error, :invalid_grant | :oauth_failed}
          | (-> String.t() | {:error, atom()})
  @type deauthorize_outcome ::
          :ok | {:error, :not_connected | :controlled_account | :oauth_failed}

  @doc """
  Expects the OAuth code exchange (`POST connect.stripe.com/oauth/token`) for
  `code`. `outcome` is the connected account ID Stripe answers with, or
  `{:error, :invalid_grant | :oauth_failed}` for a refusal, or a 0-arity
  function returning either, run when the request is made. Sends
  `{:oauth_exchange, code}` to the calling process when the request is made.
  See `expect_deauthorize/3` for the options.
  """
  @spec expect_exchange(String.t(), exchange_outcome(), keyword()) :: :ok
  def expect_exchange(code, outcome, opts \\ []),
    do: expect_route({:exchange, code, outcome}, opts)

  @doc """
  Expects the OAuth deauthorisation (`POST connect.stripe.com/oauth/deauthorize`)
  for `stripe_account_id`, answering as `outcome` says. Sends
  `{:oauth_deauthorize, stripe_account_id}` to the calling process when the
  request is made.

  Expectations accumulate: each call adds a route to the `:tymeslot_http`
  stub, so an exchange and a deauthorisation can both be expected in one test.
  A request matching no route is answered with a 400 `unexpected_request`.
  Each route must be called as often as `:times` says (default `1`; an
  integer or a range such as `0..1` for a call the test may or may not reach)
  by the time the test ends, or the test fails naming the route.
  """
  @spec expect_deauthorize(String.t(), deauthorize_outcome(), keyword()) :: :ok
  def expect_deauthorize(stripe_account_id, outcome \\ :ok, opts \\ []),
    do: expect_route({:deauthorize, stripe_account_id, outcome}, opts)

  defp expect_route(route, opts) do
    test_pid = self()
    times = Keyword.get(opts, :times, 1)
    counter = :counters.new(1, [])
    routes = [{route, counter} | Process.get(@routes_key, [])]
    Process.put(@routes_key, routes)

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      form = URI.decode_query(body)

      case Enum.find(routes, fn {route, _counter} -> route_matches?(route, conn, form) end) do
        nil ->
          json(conn, 400, %{"error" => "unexpected_request"})

        {route, counter} ->
          :counters.add(counter, 1, 1)
          answer(route, conn, test_pid)
      end
    end)

    on_exit(fn ->
      count = :counters.get(counter, 1)

      unless in_times?(count, times) do
        flunk(
          "expected #{describe(route)} to be called #{inspect(times)} time(s), " <>
            "but it was called #{count}"
        )
      end
    end)
  end

  defp in_times?(count, %Range{} = range), do: count in range
  defp in_times?(count, times), do: count == times

  defp describe({:exchange, code, _outcome}), do: "the OAuth code exchange for #{inspect(code)}"

  defp describe({:deauthorize, account_id, _outcome}),
    do: "the OAuth deauthorisation of #{inspect(account_id)}"

  defp route_matches?({:exchange, code, _outcome}, conn, form),
    do: conn.request_path == "/oauth/token" and form["code"] == code

  defp route_matches?({:deauthorize, account_id, _outcome}, conn, form),
    do: conn.request_path == "/oauth/deauthorize" and form["stripe_user_id"] == account_id

  defp answer({:exchange, code, outcome}, conn, test_pid) do
    send(test_pid, {:oauth_exchange, code})

    case if(is_function(outcome, 0), do: outcome.(), else: outcome) do
      id when is_binary(id) -> json(conn, 200, %{"stripe_user_id" => id})
      {:error, :invalid_grant} -> json(conn, 400, %{"error" => "invalid_grant"})
      {:error, :oauth_failed} -> json(conn, 500, %{"error" => "api_error"})
    end
  end

  defp answer({:deauthorize, account_id, outcome}, conn, test_pid) do
    send(test_pid, {:oauth_deauthorize, account_id})

    case outcome do
      :ok ->
        json(conn, 200, %{"stripe_user_id" => account_id})

      {:error, :not_connected} ->
        json(conn, 400, %{
          "error" => "invalid_client",
          "error_description" =>
            "This application is not connected to stripe account #{account_id}"
        })

      {:error, :controlled_account} ->
        json(conn, 400, %{"error" => "no_deauth_on_controlled_account"})

      {:error, :oauth_failed} ->
        json(conn, 500, %{"error" => "api_error"})
    end
  end

  @doc "Expects one account read for `stripe_account_id`, merging `attrs` into a bare snapshot."
  @spec expect_retrieve(String.t(), map()) :: :ok
  def expect_retrieve(stripe_account_id, attrs) do
    StripeStub.expect(:retrieve_account, 1, fn request ->
      assert request.headers["stripe-account"] == stripe_account_id
      snapshot(stripe_account_id, attrs)
    end)
  end

  @doc "A Stripe account snapshot with every capability off, overridden by `attrs`."
  @spec snapshot(String.t(), map()) :: map()
  def snapshot(stripe_account_id, attrs) do
    StripeFixtures.object(
      "account",
      Map.merge(
        %{
          "id" => stripe_account_id,
          "charges_enabled" => false,
          "payouts_enabled" => false,
          "details_submitted" => false,
          "requirements" => %{"disabled_reason" => nil}
        },
        attrs
      )
    )
  end

  defp json(conn, status, body) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end
end
