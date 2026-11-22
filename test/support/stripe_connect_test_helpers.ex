defmodule Tymeslot.StripeConnectTestHelpers do
  @moduledoc """
  Shared steps for tests that connect a host's Stripe account through OAuth,
  with the Stripe API stubbed by `Tymeslot.StripeStub` and the OAuth token
  exchange by `Req.Test` (`:tymeslot_http`).
  """

  import ExUnit.Assertions, only: [assert: 1]
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

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
          String.t() | {:error, :invalid_grant | :oauth_failed} | (-> String.t() | {:error, atom()})
  @type deauthorize_outcome ::
          :ok | {:error, :not_connected | :controlled_account | :oauth_failed}

  @doc """
  Stubs the OAuth code exchange (`POST connect.stripe.com/oauth/token`) for
  `code`. `outcome` is the connected account ID Stripe answers with, or
  `{:error, :invalid_grant | :oauth_failed}` for a refusal, or a 0-arity
  function returning either, run when the request is made. Sends
  `{:oauth_exchange, code}` to the calling process when the request is made.
  See `expect_oauth/2` for `fallback`.
  """
  @spec expect_exchange(String.t(), exchange_outcome(), (Conn.t() -> Conn.t()) | nil) :: :ok
  def expect_exchange(code, outcome, fallback \\ nil),
    do: expect_oauth([{:exchange, code, outcome}], fallback)

  @doc """
  Stubs the OAuth deauthorisation (`POST connect.stripe.com/oauth/deauthorize`)
  for `stripe_account_id`, answering as `outcome` says. Sends
  `{:oauth_deauthorize, stripe_account_id}` to the calling process when the
  request is made. See `expect_oauth/2` for `fallback`.
  """
  @spec expect_deauthorize(String.t(), deauthorize_outcome(), (Conn.t() -> Conn.t()) | nil) ::
          :ok
  def expect_deauthorize(stripe_account_id, outcome \\ :ok, fallback \\ nil),
    do: expect_oauth([{:deauthorize, stripe_account_id, outcome}], fallback)

  @doc """
  Stubs `:tymeslot_http` with the given OAuth routes, `{:exchange, code,
  outcome}` and `{:deauthorize, stripe_account_id, outcome}`, for a test that
  makes both calls. A request matching no route goes to `fallback` (a
  1-arity `Plug.Conn` function) when given, for a test that also stubs
  `:tymeslot_http` for something else, and is otherwise answered with a 400
  `unexpected_request`. Each matched request sends `{:oauth_exchange, code}`
  or `{:oauth_deauthorize, stripe_account_id}` to the calling process.
  """
  @spec expect_oauth([tuple()], (Conn.t() -> Conn.t()) | nil) :: :ok
  def expect_oauth(routes, fallback \\ nil) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      form = URI.decode_query(body)

      case Enum.find(routes, &route_matches?(&1, conn, form)) do
        nil ->
          if fallback,
            do: fallback.(conn),
            else: json(conn, 400, %{"error" => "unexpected_request"})

        route ->
          answer(route, conn, test_pid)
      end
    end)
  end

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
