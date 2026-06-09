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
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Repo
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

    # Reset stateful components to ensure test isolation
    reset_stateful_components()

    :ok
  end

  @doc """
  Resets stateful components like circuit breakers between tests.
  This ensures test isolation and prevents state pollution.
  """
  @spec reset_stateful_components() :: :ok
  def reset_stateful_components do
    # Reset calendar circuit breakers
    providers = [:caldav, :radicale, :nextcloud, :google, :outlook]

    Enum.each(providers, fn p ->
      CalendarCircuitBreaker.reset(p)
    end)

    # Host-keyed breakers are registered dynamically and are not covered by
    # the per-provider reset above
    CalendarCircuitBreaker.reset_all_hosts()

    # Reset other circuit breakers
    Enum.each([:email_service_breaker, :oauth_github_breaker, :oauth_google_breaker], fn name ->
      if Process.whereis(name), do: CircuitBreaker.reset(name)
    end)

    # Clear rate limiter
    RateLimiter.clear_all()

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
