defmodule Tymeslot.AppSettings do
  @moduledoc """
  Admin-editable application settings.

  Each setting has three layers of precedence, highest first:

    1. **DB override** — a non-nil value in the `app_settings` singleton row,
       set via the admin UI or `update/1` below.
    2. **Application config** — the value in `config.exs` / `runtime.exs`,
       typically populated from an environment variable.
    3. **Built-in default** — the fallback in `default_for/1`.

  At application boot, `load!/0` snapshots the current config-layer value for
  each key, then pushes any non-nil DB overrides into `Application.put_env/3`.
  Existing call sites (e.g. `Tymeslot.Infrastructure.Config.registration_enabled?/0`)
  read via `Application.get_env/3` and transparently see the DB-backed value
  without any code changes.

  Some settings live nested under a parent keyword list — e.g.
  `:google_auth_enabled` is projected into
  `Application.get_env(:tymeslot, :social_auth)[:google_enabled]`. The
  projection target is described by `config_path/1`; everything else (read,
  write, restore) goes through the same code path.

  On `update/1`, the same projection happens, so an admin toggling a setting
  in the UI takes effect immediately — no restart needed. Clearing an
  override (passing `nil`) restores the snapshotted config value.

  Settings are intentionally typed columns rather than a generic key/value
  store: it keeps the migration path explicit, makes the Settings API
  type-safe, and lets the LiveView render each setting with the right control.
  """

  require Logger

  alias Tymeslot.AppSettings.{AppSettingsQueries, AppSettingsSchema}
  alias Tymeslot.Auth

  @type setting_key ::
          :registration_enabled
          | :password_auth_enabled
          | :google_auth_enabled
          | :github_auth_enabled
          | :oauth_auth_enabled
          | :recaptcha_signup_enabled
          | :recaptcha_booking_enabled
          | :recaptcha_signup_min_score
          | :recaptcha_booking_min_score
          | :admin_alerts_enabled
          | :admin_alert_email

  @type effective_source :: :db | :config | :default
  @type effective_value :: %{
          value: term(),
          source: effective_source(),
          db_value: term() | nil,
          locked_states: [term()]
        }

  # Baseline = the config-layer value that was in effect before any DB
  # override was applied. Captured once per BEAM lifetime in `:persistent_term`
  # (purpose-built for read-heavy, write-rare configuration data) so reset/1
  # can restore the original config value.
  @baseline_sentinel :__app_settings_baseline_not_captured__

  @doc """
  Returns the list of admin-editable setting keys.
  """
  @spec keys() :: [setting_key()]
  def keys, do: AppSettingsSchema.editable_fields()

  @doc """
  Snapshots the current config-layer values, then applies any DB overrides on
  top. Safe to call multiple times — the baseline is only captured once per
  BEAM lifetime, so subsequent calls just re-apply current DB overrides.
  Returns `:ok` even if the DB is unreachable (defaults remain in effect).
  """
  @spec load!() :: :ok
  def load! do
    Enum.each(keys(), &capture_baseline/1)
    settings = AppSettingsQueries.get_settings()
    Enum.each(keys(), fn key -> apply_override(key, Map.get(settings, key)) end)
    :ok
  end

  @doc """
  Returns the singleton settings row (typically used to seed the admin form).
  """
  @spec get!() :: AppSettingsSchema.t()
  def get!, do: AppSettingsQueries.get_settings()

  @doc """
  Returns a map of `key -> %{value, source, db_value, locked_states}` for
  every editable setting. `value` is the effective value an admin would see;
  `source` shows whether it came from the DB, the config layer, or the
  built-in default; `locked_states` lists values the setting cannot currently
  transition to because `update/1` would reject the change (e.g. would lock
  out admins). The admin UI uses `locked_states` to disable controls
  upfront so the user never has to click and read an error.
  """
  @spec effective_values() :: %{setting_key() => effective_value()}
  def effective_values do
    settings = get!()

    Map.new(keys(), fn key ->
      db_value = Map.get(settings, key)

      {key,
       %{
         value: effective_value(key, db_value),
         source: source_for(key, db_value),
         db_value: db_value,
         locked_states: locked_states_for(key)
       }}
    end)
  end

  @doc """
  Updates one or more settings. Pass `nil` for a key to clear the DB override
  and fall back to the config/default. The new values are pushed to
  `Application.put_env` on success so the change takes effect immediately.

  Returns `{:error, :would_lock_out}` if the update would transition
  `password_auth_enabled` from true to false while at least one admin still
  signs in via email + password. Whether the install has OAuth configured
  globally is irrelevant — an admin whose own account has no linked OAuth
  identity would still be locked out. The acting admin must demote those
  password-auth admins (or have them link an OAuth identity) before the
  toggle can flip. Updates from an already locked-out state (e.g. an admin
  recovering via a still-valid session) are allowed through unchanged.
  """
  @spec update(map()) ::
          {:ok, AppSettingsSchema.t()} | {:error, Ecto.Changeset.t() | :would_lock_out}
  def update(attrs) when is_map(attrs) do
    if would_cause_lockout?(attrs) do
      Logger.warning("App settings update blocked: would lock out all users",
        keys: Map.keys(attrs)
      )

      {:error, :would_lock_out}
    else
      apply_update(attrs)
    end
  end

  defp apply_update(attrs) do
    case AppSettingsQueries.update_settings(attrs) do
      {:ok, settings} ->
        flush_overrides(settings)
        Logger.info("App settings updated", keys: Map.keys(attrs))
        {:ok, settings}

      {:error, changeset} = error ->
        Logger.warning("App settings update failed", errors: inspect(changeset.errors))
        error
    end
  end

  # Applies all setting overrides from `settings` to the Application env in a
  # way that avoids the TOCTOU window for nested keys. Keys that share a parent
  # keyword list (e.g. :social_auth, :recaptcha) are merged together before
  # being written, so each parent key receives exactly one `Application.put_env`
  # call rather than a sequence of read-modify-write operations that concurrent
  # updates could interleave.
  defp flush_overrides(settings) do
    {top_level, nested_by_parent} = partition_keys_by_layout()

    Enum.each(top_level, &apply_override(&1, Map.get(settings, &1)))

    Enum.each(nested_by_parent, fn {parent, keys} ->
      flush_nested_parent(parent, keys, settings)
    end)
  end

  defp partition_keys_by_layout do
    Enum.reduce(keys(), {[], %{}}, fn key, {top_acc, nested_acc} ->
      case config_path(key) do
        [_top] -> {[key | top_acc], nested_acc}
        [parent, _child] -> {top_acc, Map.update(nested_acc, parent, [key], &[key | &1])}
      end
    end)
  end

  defp flush_nested_parent(parent, keys, settings) do
    current = Application.get_env(:tymeslot, parent, [])
    merged = Enum.reduce(keys, current, &merge_nested_child(&2, &1, settings))
    Application.put_env(:tymeslot, parent, merged)
  end

  defp merge_nested_child(kw, key, settings) do
    [_parent, child] = config_path(key)

    case Map.get(settings, key) do
      nil -> restore_nested_child_baseline(kw, key, child)
      value -> Keyword.put(kw, child, value)
    end
  end

  defp restore_nested_child_baseline(kw, key, child) do
    case :persistent_term.get(baseline_term(key), @baseline_sentinel) do
      {:ok, value} -> Keyword.put(kw, child, value)
      :error -> Keyword.delete(kw, child)
      @baseline_sentinel -> kw
    end
  end

  # Lockout protection: refuse any update that would leave zero usable auth
  # paths *while at least one admin exists*. A path is "usable" if it is
  # enabled AND some admin can plausibly sign in through it. For password
  # auth that means the setting is on AND some admin still uses password
  # auth. For SSO providers the setting being on is sufficient (we can't
  # know in advance which identity a provider covers). When no admin
  # account exists at all the guard vacuously passes — there is no admin to
  # be locked out — which is also the only way a fresh install can disable
  # everything before its first admin signs in.
  defp would_cause_lockout?(attrs) do
    Auth.any_admin?() and
      currently_has_usable_path?() and
      not password_usable_after?(attrs) and
      not sso_usable_after?(attrs)
  end

  defp currently_has_usable_path? do
    password_currently_usable?() or sso_currently_usable?()
  end

  defp password_currently_usable? do
    read_config(:password_auth_enabled) == true and Auth.any_admin_uses_password_auth?()
  end

  defp sso_currently_usable? do
    read_config(:google_auth_enabled) == true or
      read_config(:github_auth_enabled) == true or
      read_config(:oauth_auth_enabled) == true
  end

  defp password_usable_after?(attrs) do
    next_effective_value(:password_auth_enabled, attrs) == true and
      Auth.any_admin_uses_password_auth?()
  end

  defp sso_usable_after?(attrs) do
    next_effective_value(:google_auth_enabled, attrs) == true or
      next_effective_value(:github_auth_enabled, attrs) == true or
      next_effective_value(:oauth_auth_enabled, attrs) == true
  end

  # The set of state values that `update/1` would currently reject for a
  # given setting. Mirrors the same checks `apply_update/1` enforces so the
  # admin UI can grey out the matching toggle in advance rather than
  # surfacing the rejection after the click.
  defp locked_states_for(:password_auth_enabled) do
    if would_cause_lockout?(%{password_auth_enabled: false}), do: [false], else: []
  end

  defp locked_states_for(key)
       when key in [:google_auth_enabled, :github_auth_enabled, :oauth_auth_enabled] do
    if would_cause_lockout?(%{key => false}), do: [false], else: []
  end

  defp locked_states_for(_key), do: []

  # Computes what the effective value of `key` would be after applying `attrs`,
  # without performing any side effects. Mirrors the same precedence rules
  # `apply_override/2` and `restore_baseline/1` enforce on commit.
  defp next_effective_value(key, attrs) do
    case Map.fetch(attrs, key) do
      {:ok, nil} -> baseline_or_default(key)
      {:ok, value} -> value
      :error -> read_config(key)
    end
  end

  defp baseline_or_default(key) do
    case :persistent_term.get(baseline_term(key), @baseline_sentinel) do
      {:ok, value} -> value
      _other -> default_for(key)
    end
  end

  @doc """
  Clears the DB override for `key`, falling back to the config layer or
  built-in default. Convenience wrapper over `update/1`.
  """
  @spec reset(setting_key()) ::
          {:ok, AppSettingsSchema.t()} | {:error, Ecto.Changeset.t() | :would_lock_out}
  def reset(key) when is_atom(key), do: update(%{key => nil})

  @doc """
  Built-in default for a setting, used when neither the DB nor the
  application config provides a value.
  """
  @spec default_for(setting_key()) :: term()
  def default_for(:registration_enabled), do: true
  def default_for(:password_auth_enabled), do: true
  def default_for(:google_auth_enabled), do: false
  def default_for(:github_auth_enabled), do: false
  def default_for(:oauth_auth_enabled), do: false
  def default_for(:recaptcha_signup_enabled), do: false
  def default_for(:recaptcha_booking_enabled), do: false
  def default_for(:recaptcha_signup_min_score), do: 0.3
  def default_for(:recaptcha_booking_min_score), do: 0.3
  def default_for(:admin_alerts_enabled), do: false
  def default_for(:admin_alert_email), do: nil

  # Projection from setting key to its location in the Application env.
  # Single-atom paths live at the top level; two-atom paths live nested
  # under a parent keyword list (e.g. `:social_auth` / `:recaptcha`).
  defp config_path(:google_auth_enabled), do: [:social_auth, :google_enabled]
  defp config_path(:github_auth_enabled), do: [:social_auth, :github_enabled]
  defp config_path(:oauth_auth_enabled), do: [:social_auth, :oauth_enabled]
  defp config_path(:recaptcha_signup_enabled), do: [:recaptcha, :signup_enabled]
  defp config_path(:recaptcha_booking_enabled), do: [:recaptcha, :booking_enabled]
  defp config_path(:recaptcha_signup_min_score), do: [:recaptcha, :signup_min_score]
  defp config_path(:recaptcha_booking_min_score), do: [:recaptcha, :booking_min_score]
  defp config_path(key), do: [key]

  defp capture_baseline(key) do
    term = baseline_term(key)

    case :persistent_term.get(term, @baseline_sentinel) do
      @baseline_sentinel -> :persistent_term.put(term, fetch_config(key))
      _existing -> :ok
    end
  end

  defp apply_override(key, nil), do: restore_baseline(key)
  defp apply_override(key, value), do: write_config(key, value)

  defp restore_baseline(key) do
    case :persistent_term.get(baseline_term(key), @baseline_sentinel) do
      {:ok, value} -> write_config(key, value)
      :error -> delete_config(key)
      @baseline_sentinel -> :ok
    end
  end

  defp effective_value(key, nil), do: read_config(key)
  defp effective_value(_key, value), do: value

  defp source_for(key, nil) do
    case :persistent_term.get(baseline_term(key), @baseline_sentinel) do
      {:ok, _value} -> :config
      _other -> :default
    end
  end

  defp source_for(_key, _value), do: :db

  defp baseline_term(key), do: {__MODULE__, :baseline, key}

  # --- Application env helpers (handle both top-level and nested keys) ---

  defp read_config(key) do
    case config_path(key) do
      [top] ->
        Application.get_env(:tymeslot, top, default_for(key))

      [parent, child] ->
        :tymeslot
        |> Application.get_env(parent, [])
        |> Keyword.get(child, default_for(key))
    end
  end

  defp fetch_config(key) do
    case config_path(key) do
      [top] ->
        Application.fetch_env(:tymeslot, top)

      [parent, child] ->
        case Application.fetch_env(:tymeslot, parent) do
          {:ok, kw} when is_list(kw) -> Keyword.fetch(kw, child)
          _other -> :error
        end
    end
  end

  defp write_config(key, value) do
    case config_path(key) do
      [top] ->
        Application.put_env(:tymeslot, top, value)

      [parent, child] ->
        kw = Application.get_env(:tymeslot, parent, [])
        Application.put_env(:tymeslot, parent, Keyword.put(kw, child, value))
    end
  end

  defp delete_config(key) do
    case config_path(key) do
      [top] ->
        Application.delete_env(:tymeslot, top)

      [parent, child] ->
        kw = Application.get_env(:tymeslot, parent, [])
        Application.put_env(:tymeslot, parent, Keyword.delete(kw, child))
    end
  end
end
