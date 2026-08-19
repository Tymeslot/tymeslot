defmodule Tymeslot.AppSettings.LockoutPolicy do
  @moduledoc """
  Refuses any settings update that would leave an install with no way for an
  admin to sign in.

  Lives apart from `Tymeslot.AppSettings`, which owns reading, writing and
  projecting settings: this is an authentication policy that happens to be
  enforced on a settings write, and it was roughly two fifths of that module.

  Two evaluation points, deliberately different:

    * the **commit path**, where `AppSettings` passes this as the guard
      callback to `AppSettingsQueries.update_settings/3`. It runs inside the
      `FOR UPDATE` transaction against the merged, about-to-be-committed row,
      so two concurrent admin saves serialise on the row lock and the second
      sees the first one's effect.
    * the **read path**, where the admin UI asks which toggles to grey out in
      advance. That one evaluates against the current row plus the proposed
      attributes, and carries no consistency risk: the authoritative check
      still runs under the lock.

  `would_cause_lockout?/2` also carries the `meeting_payments_enabled` guard:
  not an authentication path, but this is the only point `update/1` checks
  the merged, about-to-be-committed row, so a race-conditioned enable with no
  Stripe platform credentials configured is refused here too rather than
  only being greyed out in the UI.
  """

  alias Tymeslot.AppSettings.Env
  alias Tymeslot.Auth
  alias Tymeslot.MeetingPayments

  @doc """
  Whether applying `attrs` on top of `merged_row` would leave zero usable
  authentication paths, or would enable meeting payments with no Stripe
  platform credentials configured.
  """
  @spec would_cause_lockout?(map(), map()) :: boolean()
  # Lockout protection: refuse any update that would leave zero usable auth
  # paths *while at least one admin exists*. A path is "usable" if it is
  # enabled AND some admin can plausibly sign in through it. For password
  # auth that means the setting is on AND some admin still uses password
  # auth. For SSO providers the setting being on is sufficient (we can't
  # know in advance which identity a provider covers). When no admin
  # account exists at all the guard vacuously passes — there is no admin to
  # be locked out — which is also the only way a fresh install can disable
  # everything before its first admin signs in.
  def would_cause_lockout?(merged_row, attrs) do
    (Auth.any_admin?() and
       currently_has_usable_path?() and
       not password_usable_after?(merged_row, attrs) and
       not sso_usable_after?(merged_row, attrs)) or
      meeting_payments_would_be_unusable?(merged_row, attrs)
  end

  # Mirrors `locked_states_for(:meeting_payments_enabled, ...)` below so the
  # UI hint and the actual write-path enforcement cannot drift apart: a
  # concurrent request that races past the UI's greyed-out toggle must still
  # be refused here, under the row lock.
  defp meeting_payments_would_be_unusable?(merged_row, attrs) do
    next_effective_value(:meeting_payments_enabled, merged_row, attrs) == true and
      not MeetingPayments.platform_configured?()
  end

  defp currently_has_usable_path? do
    password_currently_usable?() or sso_currently_usable?()
  end

  defp password_currently_usable? do
    Env.read(:password_auth_enabled) == true and Auth.any_admin_uses_password_auth?()
  end

  defp sso_currently_usable? do
    sso_path_usable?(:google_auth_enabled, Env.read(:google_auth_enabled)) or
      sso_path_usable?(:github_auth_enabled, Env.read(:github_auth_enabled)) or
      sso_path_usable?(:oauth_auth_enabled, Env.read(:oauth_auth_enabled))
  end

  defp password_usable_after?(merged_row, attrs) do
    next_effective_value(:password_auth_enabled, merged_row, attrs) == true and
      Auth.any_admin_uses_password_auth?()
  end

  defp sso_usable_after?(merged_row, attrs) do
    sso_path_usable?(
      :google_auth_enabled,
      next_effective_value(:google_auth_enabled, merged_row, attrs)
    ) or
      sso_path_usable?(
        :github_auth_enabled,
        next_effective_value(:github_auth_enabled, merged_row, attrs)
      ) or
      sso_path_usable?(
        :oauth_auth_enabled,
        next_effective_value(:oauth_auth_enabled, merged_row, attrs)
      )
  end

  # An SSO provider only counts as a usable auth path when it is BOTH enabled
  # AND has its client credentials configured. Enabling e.g. generic OIDC with
  # no OAUTH_CLIENT_ID/OAUTH_CLIENT_SECRET set produces a login button that
  # cannot complete a sign-in, so it must not satisfy the lockout guard — an
  # admin could otherwise enable a credential-less provider, disable password
  # auth, and brick the install. Mirrors the `MeetingPayments.platform_configured?()`
  # pattern used for the meeting-payments lock.
  defp sso_path_usable?(_key, enabled?) when enabled? != true, do: false
  defp sso_path_usable?(key, _enabled?), do: sso_credentials_present?(key)

  @doc """
  Returns `true` when the OAuth provider behind `key` has both a client id and
  client secret configured. Used by the lockout guard so a credential-less
  SSO toggle is not mistaken for a working sign-in path.
  """
  @spec sso_credentials_present?(atom()) :: boolean()
  def sso_credentials_present?(:google_auth_enabled) do
    env_present?("GOOGLE_CLIENT_ID") and env_present?("GOOGLE_CLIENT_SECRET")
  end

  def sso_credentials_present?(:github_auth_enabled) do
    env_present?("GITHUB_CLIENT_ID") and env_present?("GITHUB_CLIENT_SECRET")
  end

  def sso_credentials_present?(:oauth_auth_enabled) do
    config = Application.get_env(:tymeslot, :oauth_provider, [])

    value_present?(Keyword.get(config, :client_id)) and
      value_present?(Keyword.get(config, :client_secret))
  end

  def sso_credentials_present?(_key), do: false

  defp env_present?(var), do: value_present?(System.get_env(var))

  defp value_present?(nil), do: false
  defp value_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp value_present?(_value), do: false

  @doc """
  The state values `update/1` would currently reject for `key`, so the admin UI
  can grey the matching toggle out in advance rather than surfacing the
  rejection after the click.
  """
  @spec locked_states_for(atom(), map()) :: [boolean()]
  def locked_states_for(:password_auth_enabled, current_row) do
    if would_cause_lockout?(current_row, %{password_auth_enabled: false}), do: [false], else: []
  end

  def locked_states_for(key, current_row)
      when key in [:google_auth_enabled, :github_auth_enabled, :oauth_auth_enabled] do
    if would_cause_lockout?(current_row, %{key => false}), do: [false], else: []
  end

  def locked_states_for(:meeting_payments_enabled, _current_row) do
    if MeetingPayments.platform_configured?(), do: [], else: [true]
  end

  def locked_states_for(_key, _current_row), do: []

  # Computes what the effective value of `key` would be after applying `attrs`,
  # without performing any side effects. Precedence: an explicit value in the
  # update wins; clearing an override (`nil`) falls back to the captured
  # baseline; an absent key falls back to the value already persisted in the
  # merged row (DB override) or, failing that, the config layer. Evaluating
  # absent keys against `merged_row` rather than the live Application env is
  # what makes the commit-path guard see concurrent writes.
  defp next_effective_value(key, merged_row, attrs) do
    case Map.fetch(attrs, key) do
      {:ok, nil} -> baseline_or_default(key)
      {:ok, value} -> value
      :error -> row_value_or_config(key, merged_row)
    end
  end

  defp row_value_or_config(key, merged_row) do
    case Map.get(merged_row, key) do
      nil -> Env.read(key)
      value -> value
    end
  end

  defp baseline_or_default(key) do
    case Env.baseline_value(key) do
      {:ok, value} -> value
      _other -> Env.default_for(key)
    end
  end
end
