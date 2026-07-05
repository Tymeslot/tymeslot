defmodule Tymeslot.Mocks.Subscription do
  @moduledoc """
  SaaS subscription manager mocks.

  See `Tymeslot.TestMocks` for the public API (`setup_subscription_mocks/1`).
  """

  import Mox

  @spec setup(keyword()) :: term()
  def setup(opts \\ []) do
    show_branding = Keyword.get(opts, :show_branding, true)

    stub(Tymeslot.Payments.SubscriptionManagerMock, :should_show_branding?, fn _user_id ->
      show_branding
    end)

    stub_subscriptions_provider(opts)
  end

  # The SaaS `SubscriptionFeatureGates` dashboard hook (wired into Core's hook
  # chain via `config :tymeslot, :dashboard_additional_hooks`) calls
  # `has_pro_access?/1` on the configured provider during every dashboard
  # LiveView mount. Under `set_mox_from_context` in shared mode (`async: false`),
  # dispatching an un-stubbed mock writes `nil` into the shared owner's
  # NimbleOwnership map, which then makes `verify_on_exit!` crash with
  # `Protocol.UndefinedError` while enumerating expectations. A default stub
  # keeps the hook — and every dashboard LiveView test — well-behaved.
  #
  # Resolved through the same config key the hook reads so this stays a no-op in
  # Core-only runs, where the SaaS provider mock (and the hook itself) are absent.
  #
  # Defaults to `nil`, which the hook treats as "subscription status unavailable"
  # and answers by preserving Core's default feature assigns without overriding
  # them. That leaves Core LiveView tests in control of feature flags through the
  # Core `:feature_assigns` lever — exactly the behaviour that held before this
  # stub existed, when the hook's un-stubbed call raised and was rescued to `nil`.
  # Tests that specifically exercise SaaS plan gating stub `has_pro_access?`
  # themselves (with a real boolean), overriding this default.
  defp stub_subscriptions_provider(opts) do
    has_pro = Keyword.get(opts, :has_pro_access, nil)

    with provider when is_atom(provider) and not is_nil(provider) <-
           Application.get_env(:tymeslot_saas, :subscriptions_provider),
         true <- Code.ensure_loaded?(provider) and function_exported?(provider, :__mock_for__, 0) do
      stub(provider, :has_pro_access?, fn _user_id -> has_pro end)
    else
      _no_provider_mock -> :ok
    end
  end
end
