defmodule TymeslotWeb.Dashboard.PaymentsControllerTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :database
  @moduletag :payments

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Phoenix.Token
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.LogCapture
  alias TymeslotWeb.Endpoint

  setup :verify_on_exit!

  setup do
    RateLimiter.clear_all()
    previous_payments = Application.get_env(:tymeslot, :meeting_payments_enabled)
    Application.put_env(:tymeslot, :meeting_payments_enabled, true)

    previous_checker = Application.get_env(:tymeslot, :feature_access_checker)

    Application.put_env(
      :tymeslot,
      :feature_access_checker,
      Tymeslot.Features.DefaultAccessChecker
    )

    on_exit(fn ->
      Application.put_env(:tymeslot, :meeting_payments_enabled, previous_payments)

      if previous_checker do
        Application.put_env(:tymeslot, :feature_access_checker, previous_checker)
      else
        Application.delete_env(:tymeslot, :feature_access_checker)
      end
    end)

    :ok
  end

  test "POST connect redirects to Stripe's authorise page", %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    conn = post(conn, "/dashboard/payments/connect")

    assert %URI{host: "connect.stripe.com", path: "/oauth/authorize"} =
             URI.parse(redirected_to(conn, 302))
  end

  test "POST connect explains a missing client ID", %{conn: conn} do
    with_config(:tymeslot, stripe_connect_client_id: nil)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    conn = post(conn, "/dashboard/payments/connect")
    assert redirected_to(conn) == "/dashboard/payments"
    assert Flash.get(conn.assigns.flash, :error) =~ "not fully set up on this server"
  end

  test "POST connect refuses a host who already has a Stripe account connected", %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    insert(:connect_account, user: user, oauth_connected_at: DateTime.utc_now(:second))

    conn = conn |> log_in_user(user) |> post("/dashboard/payments/connect")

    assert redirected_to(conn) == "/dashboard/payments"
    assert Flash.get(conn.assigns.flash, :error) == "A Stripe account is already connected."
  end

  test "POST /dashboard/payments/connect is rejected when the feature is disabled", %{conn: conn} do
    # Forged request: the UI hides the button, but a direct POST must not be
    # able to start onboarding when the operator toggle is off. No Stripe call
    # is expected — Mox verify_on_exit! enforces this.
    Application.put_env(:tymeslot, :meeting_payments_enabled, false)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    conn = post(conn, "/dashboard/payments/connect")

    assert redirected_to(conn) == "/dashboard/payments"
    assert Flash.get(conn.assigns.flash, :error) =~ "not enabled"
  end

  describe "GET /dashboard/payments/connect/callback" do
    setup do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
      insert(:profile, user: user)
      %{user: user}
    end

    test "callback connects and returns to payments with a resync marker", %{user: user} do
      state = start_state(user)
      expect_connection("acct_cb", "eur")

      conn = callback(user, state)

      assert redirected_to(conn) == "/dashboard/payments?return=1"
      assert Flash.get(conn.assigns.flash, :info) == "Stripe connected."

      assert Repo.get_by!(ConnectAccountSchema, user_id: user.id).stripe_account_id == "acct_cb"
    end

    test "a denied connection flashes cancelled and needs no state", %{user: user} do
      conn =
        get(as(user), "/dashboard/payments/connect/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == "/dashboard/payments"
      assert Flash.get(conn.assigns.flash, :info) == "Stripe connection cancelled."
    end

    test "any other Stripe error flashes a failure", %{user: user} do
      conn =
        get(as(user), "/dashboard/payments/connect/callback", %{
          "error" => "server_error",
          "error_description" => "secret detail"
        })

      assert redirected_to(conn) == "/dashboard/payments"
      assert Flash.get(conn.assigns.flash, :error) =~ "Stripe could not complete"
      refute Flash.get(conn.assigns.flash, :error) =~ "secret detail"
    end

    test "callback requires a logged-in host", %{conn: conn} do
      # No adapter expectation is set: Mox raises if Stripe is reached.
      requested = "/dashboard/payments/connect/callback?code=c1&state=x"
      conn = get(conn, requested)

      assert redirected_to(conn) ==
               "/auth/login?" <> URI.encode_query(%{"redirect_to" => requested})
    end

    test "a host whose session lapsed signs in and completes the connection", %{conn: conn} do
      password = "Password123!"
      email = "lapsed-host@example.com"

      user =
        insert(:user,
          email: email,
          verified_at: DateTime.utc_now(:second),
          onboarding_completed_at: DateTime.utc_now(:second)
        )

      insert(:profile, user: user)
      state = start_state(user)
      requested = "/dashboard/payments/connect/callback?code=c1&state=#{state}"

      login = conn |> get(requested) |> redirected_to()
      assert login == "/auth/login?" <> URI.encode_query(%{"redirect_to" => requested})

      signed_in =
        conn
        |> recycle()
        |> get(login)
        |> recycle()
        |> post("/auth/session", %{"email" => email, "password" => password})

      assert redirected_to(signed_in) == requested

      expect_connection("acct_resumed", "eur")
      resumed = signed_in |> recycle() |> get(requested)

      assert redirected_to(resumed) == "/dashboard/payments?return=1"

      assert Repo.get_by!(ConnectAccountSchema, user_id: user.id).stripe_account_id ==
               "acct_resumed"
    end

    test "a malformed error, code or state is refused and claims no nonce", %{user: user} do
      state = start_state(user)
      nonce = Repo.get_by!(ConnectAccountSchema, user_id: user.id).oauth_nonce
      assert byte_size(nonce) > 0

      queries = [
        "error[x]=y",
        "error[]=a",
        "code[x]=y&state=#{state}",
        "code[]=a&state=#{state}",
        "code=c1&state[x]=#{state}"
      ]

      for query <- queries do
        conn = get(as(user), "/dashboard/payments/connect/callback?" <> query)

        assert redirected_to(conn) == "/dashboard/payments", query
        assert Flash.get(conn.assigns.flash, :error) =~ "no longer valid", query
        assert Repo.get_by!(ConnectAccountSchema, user_id: user.id).oauth_nonce == nonce, query
      end
    end

    test "a failure after Stripe approved says the connection did not complete", %{user: user} do
      state = start_state(user)
      expect_connection("acct_badcountry", "eur", country: 123)

      conn = callback(user, state)

      assert redirected_to(conn) == "/dashboard/payments"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Stripe could not complete the connection. Please try again."
    end

    test "callback with neither code nor error is refused", %{user: user} do
      conn = get(as(user), "/dashboard/payments/connect/callback")

      assert redirected_to(conn) == "/dashboard/payments"
      assert Flash.get(conn.assigns.flash, :error) =~ "no longer valid"
    end

    test "a forged state is refused without reaching Stripe", %{user: user} do
      conn =
        get(as(user), "/dashboard/payments/connect/callback", %{
          "code" => "c1",
          "state" => "forged"
        })

      assert redirected_to(conn) == "/dashboard/payments"
      assert Flash.get(conn.assigns.flash, :error) =~ "no longer valid"
    end

    @refusals [
      {:invalid_grant, "Stripe could not complete the connection. Please try again."},
      {:oauth_failed, "Stripe could not complete the connection. Please try again."},
      {:user_mismatch, "That Stripe connection link is no longer valid. Please try again."},
      {:expired_state, "That Stripe connection link is no longer valid. Please try again."},
      {:state_already_used, "That Stripe connection link is no longer valid. Please try again."},
      {:account_already_linked,
       "That Stripe account is already connected to another Tymeslot account."},
      {:unsupported_currency,
       "That Stripe account uses a currency Tymeslot doesn't support for payments yet."}
    ]

    for {reason, message} <- @refusals do
      test "refusal #{reason} shows its own message", %{user: user} do
        conn = refuse(unquote(reason), user)

        assert redirected_to(conn) == "/dashboard/payments"
        assert Flash.get(conn.assigns.flash, :error) == unquote(message)
      end
    end

    @tag :capture_log
    test "a failing callback logs neither the code, the state nor the error description", %{
      user: user
    } do
      LogCapture.attach(level: :all, logger_level: :debug)

      conn =
        get(as(user), "/dashboard/payments/connect/callback", %{
          "code" => "code-SECRET-91bc",
          "state" => "state-SECRET-7f3a",
          "error_description" => "desc-SECRET-5d2e"
        })

      assert redirected_to(conn) == "/dashboard/payments"

      get(as(user), "/dashboard/payments/connect/callback", %{
        "error" => "server_error",
        "error_description" => "desc-SECRET-5d2e"
      })

      # Phoenix's own request line ("Processing with ... Parameters: ...") echoes the
      # query string at debug level, which production never emits (it runs at
      # :info); this test is about what the callback itself logs.
      events =
        Enum.reject(LogCapture.drain(), &(LogCapture.message_text(&1.msg) =~ "Processing with"))

      # Anchor: the failure was logged, so an empty capture cannot pass this.
      assert Enum.any?(events, &(LogCapture.message_text(&1.msg) =~ "Stripe Connect"))

      for event <- events do
        logged = LogCapture.message_text(event.msg) <> inspect(LogCapture.user_metadata(event))
        refute logged =~ "code-SECRET-91bc"
        refute logged =~ "state-SECRET-7f3a"
        refute logged =~ "desc-SECRET-5d2e"
      end
    end

    test "too many callbacks are refused", %{user: user} do
      conn = Enum.reduce(1..21, nil, fn _attempt, _previous -> callback(user, "forged") end)

      assert Flash.get(conn.assigns.flash, :error) =~ "Too many requests"
    end
  end

  # Drives the real callback into the failure named by `reason`.
  defp refuse(:invalid_grant, user), do: failed_exchange(user, :invalid_grant)
  defp refuse(:oauth_failed, user), do: failed_exchange(user, :oauth_failed)

  defp refuse(:user_mismatch, user) do
    other = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: other)
    callback(user, start_state(other))
  end

  defp refuse(:expired_state, user) do
    start_state(user)
    nonce = Repo.get_by!(ConnectAccountSchema, user_id: user.id).oauth_nonce

    aged =
      Token.sign(Endpoint, "stripe_connect_state", %{user_id: user.id, nonce: nonce},
        signed_at: System.system_time(:second) - 25 * 3600
      )

    callback(user, aged)
  end

  defp refuse(:state_already_used, user) do
    state = start_state(user)
    expect_connection("acct_once", "eur")
    callback(user, state)
    callback(user, state)
  end

  defp refuse(:account_already_linked, user) do
    state = start_state(user)
    insert(:connect_account, stripe_account_id: "acct_taken")

    expect(StripeAdapterMock, :exchange_oauth_code, fn _code ->
      {:ok, %{stripe_user_id: "acct_taken"}}
    end)

    callback(user, state)
  end

  defp refuse(:unsupported_currency, user) do
    state = start_state(user)
    expect_connection("acct_jpy", "jpy")
    callback(user, state)
  end

  defp failed_exchange(user, error) do
    state = start_state(user)
    expect(StripeAdapterMock, :exchange_oauth_code, fn _code -> {:error, error} end)
    callback(user, state)
  end

  defp as(user), do: build_conn() |> init_test_session(%{}) |> log_in_user(user)

  defp start_state(user) do
    %URI{query: query} =
      as(user)
      |> post("/dashboard/payments/connect")
      |> redirected_to(302)
      |> URI.parse()

    URI.decode_query(query)["state"]
  end

  defp callback(user, state) do
    get(as(user), "/dashboard/payments/connect/callback", %{"code" => "c1", "state" => state})
  end

  defp expect_connection(account_id, currency, opts \\ []) do
    expect(StripeAdapterMock, :exchange_oauth_code, fn _code ->
      {:ok, %{stripe_user_id: account_id}}
    end)

    expect(StripeAdapterMock, :retrieve_account, fn ^account_id ->
      {:ok,
       %{
         "id" => account_id,
         "country" => Keyword.get(opts, :country, "DE"),
         "default_currency" => currency,
         "charges_enabled" => false,
         "payouts_enabled" => false,
         "details_submitted" => false,
         "requirements" => %{"disabled_reason" => nil}
       }}
    end)
  end
end
