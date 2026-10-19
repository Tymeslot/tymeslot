defmodule Tymeslot.AppSettings do
  @moduledoc """
  Admin-editable application settings.

  Each setting has up to four layers of precedence, highest first:

    1. **Environment pin**: the operator set the setting's environment
       variable, so `config/runtime.exs` lists it in `:env_pinned_settings`.
       The config value stands, the admin UI shows it greyed out, and
       `update/1` refuses to store a value for it. A value stored earlier is
       kept and applies again once the variable is removed.
    2. **DB override**: a non-nil value in the `app_settings` singleton row,
       set via the admin UI or `update/1` below.
    3. **Application config**: the value in `config.exs` / `runtime.exs`.
    4. **Built-in default**: the fallback in `default_for/1`.

  At application boot, `load!/0` snapshots the current config-layer value for
  each key, then pushes any non-nil DB overrides into `Application.put_env/3`,
  skipping pinned keys so their config value stands.
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

  Note: `Application.put_env/3` is node-local. On a multi-node deployment an
  override applied via `update/1` only takes effect immediately on the node
  that handled the request; other nodes pick it up at their next `load!/0`
  (restart). This is acceptable for the single-node self-hosted target this
  module serves.
  """

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.AppSettings.{AppSettingsQueries, AppSettingsSchema, Env}
  alias Tymeslot.AppSettings.LockoutPolicy
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Payments.Webhooks.SecretCheck

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
          | :meeting_payments_enabled
          | :booking_analytics_enabled
          | :email_brand_name
          | :email_brand_accent
          | :email_logo_path
          | :admin_default_locale
          | :booking_default_locale

  @type effective_source :: :env | :db | :config | :default
  @type effective_value :: %{
          value: term(),
          source: effective_source(),
          db_value: term() | nil,
          env_var: String.t() | nil,
          locked_states: [term()]
        }

  @type update_error ::
          Changeset.t() | :would_lock_out | {:pinned, setting_key(), String.t()}

  @doc """
  Returns the list of admin-editable setting keys.
  """
  @spec keys() :: [setting_key()]
  def keys, do: AppSettingsSchema.editable_fields()

  @doc """
  Snapshots the current config-layer values, then applies any DB overrides on
  top, except to pinned keys. Safe to call multiple times — the baseline is
  only captured once per BEAM lifetime, so subsequent calls just re-apply
  current DB overrides.
  Returns `:ok` even if the DB is unreachable (defaults remain in effect).
  """
  @spec load!() :: :ok
  def load! do
    Env.capture_baselines()
    settings = AppSettingsQueries.get_settings()
    Env.apply_overrides(settings)
    :ok
  end

  @doc """
  Child spec that applies the DB overrides while the supervision tree starts.

  Placed after the Repo and before Oban and the Endpoint, so no request or job
  ever runs on the config-layer values an admin has overridden (registration
  disabled, reCAPTCHA required). The child calls `load!/0` synchronously and
  returns `:ignore`, leaving no process behind. Not `:temporary`: the
  supervisor keeps an ignored child's spec only for the other restart types,
  and that spec is what shows the loader's place in the tree.
  """
  @spec loader_child_spec() :: Supervisor.child_spec()
  def loader_child_spec do
    %{id: __MODULE__.Loader, start: {__MODULE__, :start_loader, []}, restart: :transient}
  end

  @doc false
  @spec start_loader() :: :ignore
  def start_loader do
    load!()
    :ignore
  end

  @doc """
  Returns the singleton settings row (typically used to seed the admin form).
  """
  @spec get!() :: AppSettingsSchema.t()
  def get!, do: AppSettingsQueries.get_settings()

  @doc """
  Effective value for a single setting, without touching the database.

  DB overrides are pushed into the Application env by `load!/0` at boot and by
  `update/1` on change, so reading the env layer here already accounts for
  them; the built-in default fills in when neither layer has a value. Use this
  rather than `Application.get_env/3` at call sites, so a setting whose default
  is meaningful (rather than `nil`) resolves in one place.
  """
  @spec get(setting_key()) :: term()
  def get(key) when is_atom(key), do: Env.read(key)

  @doc """
  Returns a map of `key -> %{value, source, db_value, env_var, locked_states}`
  for every editable setting. `value` is the effective value an admin would
  see; `source` shows whether it came from an environment pin (`:env`), the
  DB, the config layer, or the built-in default; `env_var` names the
  environment variable that pins the setting, or is `nil` when none does
  (`db_value` still reports any value stored before the pin);
  `locked_states` lists values the setting cannot currently transition to
  because `update/1` would reject the change (e.g. would lock out admins).
  The admin UI uses `locked_states` to disable controls upfront so the user
  never has to click and read an error.
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
         env_var: Env.pinned_var(key),
         locked_states: LockoutPolicy.locked_states_for(key, settings)
       }}
    end)
  end

  @doc """
  Updates one or more settings. Pass `nil` for a key to clear the DB override
  and fall back to the config/default. The new values are pushed to
  `Application.put_env` on success so the change takes effect immediately.

  Returns `{:error, :would_lock_out}` if the update would leave the install
  with no usable auth path while at least one admin exists — e.g. disabling
  `password_auth_enabled` while an admin still signs in via email + password
  and no SSO provider is both enabled *and* has client credentials
  configured. An SSO provider that is toggled on but has no client id/secret
  set does not count as a usable path (the login button cannot complete a
  sign-in), so enabling a credential-less provider does not unlock the
  password-auth toggle. The acting admin must demote password-auth admins
  (or configure/keep a credentialed SSO provider) before the toggle can flip.
  Updates from an already locked-out state (e.g. an admin recovering via a
  still-valid session) are allowed through unchanged.

  Returns `{:error, {:pinned, key, var}}`, storing nothing, when a non-nil
  value targets a setting the environment variable `var` fixes.

  String keys are accepted and normalised against `keys/0`; an unrecognised
  key returns an `{:error, %Ecto.Changeset{}}` rather than silently applying.

  The lockout guard is evaluated inside the row-locked update transaction,
  against the merged row about to be committed — so two concurrent saves
  cannot each pass the check and jointly disable the last auth path.
  """
  @spec update(map()) :: {:ok, AppSettingsSchema.t()} | {:error, update_error()}
  def update(attrs) when is_map(attrs) do
    with {:ok, normalised} <- normalise_keys(attrs),
         :ok <- reject_pinned(normalised) do
      apply_update(normalised)
    end
  end

  # Normalise incoming attribute keys to the atom whitelist before any guard
  # runs. The schema cast accepts string keys, so without this an admin call
  # like `update(%{"password_auth_enabled" => false})` would skip the
  # atom-keyed lockout guard yet still apply through the cast. We map every
  # known string key to its atom equivalent and reject any unknown key.
  defp normalise_keys(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalise_key(key) do
        {:ok, atom_key} -> {:cont, {:ok, Map.put(acc, atom_key, value)}}
        :error -> {:halt, {:error, unknown_key_changeset(key)}}
      end
    end)
  end

  defp normalise_key(key) when is_atom(key) do
    if key in keys(), do: {:ok, key}, else: :error
  end

  defp normalise_key(key) when is_binary(key) do
    case Enum.find(keys(), fn k -> Atom.to_string(k) == key end) do
      nil -> :error
      atom_key -> {:ok, atom_key}
    end
  end

  defp normalise_key(_key), do: :error

  # A value for a setting an environment variable fixes would be stored but
  # never take effect, so it is refused. Clearing a stored value (nil) is
  # allowed: it cannot conflict with the pin.
  defp reject_pinned(attrs) do
    Enum.find_value(attrs, :ok, fn {key, value} ->
      var = Env.pinned_var(key)

      if var && value != nil do
        Logger.warning("App settings update blocked: setting is fixed by an environment variable",
          key: key,
          env_var: var
        )

        {:error, {:pinned, key, var}}
      end
    end)
  end

  defp unknown_key_changeset(key) do
    %AppSettingsSchema{}
    |> Changeset.change()
    |> Changeset.add_error(:base, "unknown setting key: #{inspect(key)}")
  end

  # The lockout guard runs *inside* the FOR-UPDATE transaction
  # (`update_settings/3`), evaluated against the merged, about-to-be-committed
  # row rather than against the live Application env. Evaluating against the
  # locked DB state closes the TOCTOU window: two concurrent admin saves
  # serialise on the row lock, so the second one sees the first one's effect
  # and cannot also disable the last remaining auth path.
  defp apply_update(attrs) do
    case AppSettingsQueries.update_settings(attrs, &lockout_guard(&1, attrs)) do
      {:ok, settings} ->
        Env.flush_overrides(settings)
        Logger.info("App settings updated", keys: Map.keys(attrs))
        AdminAlerts.check_config()
        maybe_check_connect_secret(attrs)
        {:ok, settings}

      {:error, :would_lock_out} = error ->
        Logger.warning("App settings update blocked: would lock out all users",
          keys: Map.keys(attrs)
        )

        error

      {:error, changeset} = error ->
        Logger.warning("App settings update failed", errors: LogFormat.reason(changeset.errors))
        error
    end
  end

  # Switching meeting payments on makes the Connect webhook secret required;
  # say so now if it is missing, rather than at the next boot. Only a save
  # that touches the toggle checks, so unrelated saves do not repeat the log.
  defp maybe_check_connect_secret(%{meeting_payments_enabled: _value}) do
    _missing = SecretCheck.check_connect()
    :ok
  end

  defp maybe_check_connect_secret(_attrs), do: :ok

  # Guard callback invoked under the row lock with the merged settings row
  # (the exact state that is about to be committed). Returns `:ok` to allow
  # the commit or `{:error, :would_lock_out}` to roll it back.
  defp lockout_guard(merged_row, attrs) do
    if LockoutPolicy.would_cause_lockout?(merged_row, attrs),
      do: {:error, :would_lock_out},
      else: :ok
  end

  @doc """
  Logs an error when the environment variables fixing the authentication
  settings leave no admin a way to sign in, naming the variables and how to
  recover. Run at boot, after `load!/0`; see
  `LockoutPolicy.pins_blocking_sign_in/0` for when it fires.
  """
  @spec warn_if_pins_block_sign_in() :: :ok
  def warn_if_pins_block_sign_in do
    case LockoutPolicy.pins_blocking_sign_in() do
      [] ->
        :ok

      pins ->
        vars = Enum.map_join(pins, ", ", fn {_key, var} -> var end)

        Logger.error(
          "No admin can sign in: no sign-in method is usable, and the environment " <>
            "variables #{vars} fix sign-in settings, so the admin page cannot turn " <>
            "one back on. Unset these variables, or correct them (for example, " <>
            "enable a provider whose client ID and secret are set), then restart.",
          env_vars: Enum.map(pins, fn {_key, var} -> var end)
        )
    end
  end

  @doc """
  Logs a warning for each environment variable whose value does not fix its
  setting, as `Tymeslot.AppSettings.EnvPins` decided in `config/runtime.exs`,
  naming the variable, its value and the values it accepts. Run at boot, so
  the warning reaches the configured log handlers, which runtime.exs runs
  before.
  """
  @spec warn_unrecognised_env_values() :: :ok
  def warn_unrecognised_env_values do
    :tymeslot
    |> Application.get_env(:env_unrecognised_settings, [])
    |> Enum.each(fn %{var: var, value: value, accepted: accepted} ->
      Logger.warning(
        "#{var}=#{inspect(value)} is not a recognised value, so it does not fix the " <>
          "setting: the admin settings page can still change it. #{var} accepts " <>
          "#{accepted}.",
        env_var: var
      )
    end)
  end

  @doc """
  Logs a warning for each setting whose environment variable now overrides a
  different value saved on the admin settings page, naming the variable, the
  value it fixes and the saved one it hides. An install upgraded with an old
  `.env` (`ENABLE_GOOGLE_AUTH=false` from the example file, say) would
  otherwise switch off what an admin had turned on, without a word. Run at
  boot, after `load!/0`.
  """
  @spec warn_pins_overriding_saved_values() :: :ok
  def warn_pins_overriding_saved_values do
    settings = get!()

    Enum.each(keys(), fn key ->
      saved = Map.get(settings, key)
      var = Env.pinned_var(key)
      pinned = Env.read(key)

      if var && not is_nil(saved) && saved != pinned do
        Logger.warning(
          "#{var} fixes #{key} to #{inspect(pinned)}, overriding #{inspect(saved)} saved " <>
            "on the admin settings page. Unset #{var} to use the saved value.",
          env_var: var
        )
      end
    end)
  end

  @doc """
  Clears the DB override for `key`, falling back to the config layer or
  built-in default. Convenience wrapper over `update/1`.
  """
  @spec reset(setting_key()) :: {:ok, AppSettingsSchema.t()} | {:error, update_error()}
  def reset(key) when is_atom(key), do: update(%{key => nil})

  @doc """
  Built-in default for a setting, used when neither the DB nor the
  application config provides a value.
  """
  @spec default_for(setting_key()) :: term()
  defdelegate default_for(key), to: Env

  defp effective_value(key, db_value) do
    if is_nil(db_value) or Env.pinned?(key), do: Env.read(key), else: db_value
  end

  defp source_for(key, db_value) do
    cond do
      Env.pinned?(key) -> :env
      not is_nil(db_value) -> :db
      match?({:ok, _value}, Env.baseline_value(key)) -> :config
      true -> :default
    end
  end
end
