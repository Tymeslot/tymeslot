defmodule Tymeslot.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  database access.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Tymeslot.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Changeset
  alias Tymeslot.Auth.Verification
  alias Tymeslot.Auth.VerificationMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Repo
  alias Tymeslot.Security.AccountLockout
  alias Tymeslot.Security.RateLimiter

  using do
    quote do
      alias Tymeslot.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Tymeslot.DataCase
      import Tymeslot.Factory
    end
  end

  setup tags do
    setup_sandbox(tags)
    Mox.set_mox_from_context(tags)

    # Safe HTTP client fallback so CalDAV validation paths don't crash
    # with Mox.UnexpectedCallError. Tests override with expect/4 as needed.
    Mox.stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    Mox.stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    # Safe Stripe adapter fallback — meeting-payments handlers backfill
    # stripe_charge_id by retrieving the payment intent. Tests that don't
    # care about the backfill get a benign no-charge response so the handler
    # logs a warning and continues without crashing.
    Mox.stub(Tymeslot.MeetingPayments.StripeAdapterMock, :retrieve_payment_intent, fn _id,
                                                                                      _opts ->
      {:ok, %{"latest_charge" => nil}}
    end)

    stub_verification_default()

    reset_stateful_components(tags)

    :ok
  end

  @doc """
  Points the verification mock at the real implementation.

  Registration reads its verification module through the same
  `:verification_module` key the session controller mocks, so without a default
  the mock would swallow every signup. Delegating keeps signup tests on the real
  implementation while leaving the seam available to a test that sets its own
  expectation.
  """
  @spec stub_verification_default() :: :ok
  def stub_verification_default do
    Mox.stub(VerificationMock, :verify_user_email, &Verification.verify_user_email/3)

    :ok
  end

  @doc """
  Resets the stateful components shared by the whole VM: the circuit breakers,
  the rate-limiter and account-lockout ETS tables, and the availability cache.

  **Sync modules only, which is why this takes the test tags and does nothing
  for an async one.** None of that state is scoped to the test process, so a
  reset issued from an async test's setup wipes state that other async tests
  are part-way through relying on. A test that primes a rate-limit bucket loses
  it the moment any concurrent setup fires, and a per-test-unique bucket key is
  no defence against a table-wide delete. That is the mechanism behind a class
  of seed-dependent failures this suite used to carry; `--seed 636119` was one
  reproduction.

  Sync modules are safe: `ExUnit.Runner` takes them only once every async
  module has finished, and runs them one at a time, so nothing is concurrently
  depending on what they clear.

  An async test therefore has to scope its own reset: derive a bucket key
  unique to the test and clear just that one with
  `Tymeslot.Security.RateLimiter.clear_bucket/1`. A test that genuinely needs
  global state reset (a circuit breaker, usually) belongs in a sync module
  instead; `calendar_api_circuit_breaker_test.exs` is the precedent.
  """
  @spec reset_stateful_components(map()) :: :ok
  def reset_stateful_components(%{async: true}), do: :ok

  def reset_stateful_components(_tags) do
    # Reset calendar circuit breakers
    providers = [:caldav, :radicale, :nextcloud, :google, :outlook]

    Enum.each(providers, fn p ->
      CalendarCircuitBreaker.reset(p)
    end)

    # Host-keyed breakers are registered dynamically and are not covered by
    # the per-provider reset above
    CalendarCircuitBreaker.reset_all_hosts()

    # Video provider breakers. These matter now that `ProviderAdapter` routes
    # room create/update/delete through them: three induced provider failures
    # in one test would otherwise open the breaker for every test after it.
    Enum.each([:mirotalk, :google_meet, :teams, :zoom], &VideoCircuitBreaker.reset/1)

    # Reset other circuit breakers
    Enum.each([:email_service_breaker, :oauth_github_breaker, :oauth_google_breaker], fn name ->
      if Process.whereis(name), do: CircuitBreaker.reset(name)
    end)

    # Clear rate limiter
    RateLimiter.clear_all()

    # Clear the account-lockout table. It is a second VM-global ETS table,
    # owned by AccountLockout.TableOwner rather than by Hammer, so the
    # rate-limiter reset above does not reach it.
    AccountLockout.clear_all()

    # Clear availability cache
    AvailabilityCache.clear_all()

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  @spec setup_sandbox(map()) :: :ok
  def setup_sandbox(tags) do
    shared = not tags[:async]
    pid = Sandbox.start_owner!(Repo, shared: shared)

    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  @spec errors_on(Ecto.Changeset.t()) :: map()
  def errors_on(changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
