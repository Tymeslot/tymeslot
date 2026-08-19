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

  @type effective_source :: :db | :config | :default
  @type effective_value :: %{
          value: term(),
          source: effective_source(),
          db_value: term() | nil,
          locked_states: [term()]
        }

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
    Env.capture_baselines()
    settings = AppSettingsQueries.get_settings()
    Env.apply_overrides(settings)
    :ok
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

  String keys are accepted and normalised against `keys/0`; an unrecognised
  key returns an `{:error, %Ecto.Changeset{}}` rather than silently applying.

  The lockout guard is evaluated inside the row-locked update transaction,
  against the merged row about to be committed — so two concurrent saves
  cannot each pass the check and jointly disable the last auth path.
  """
  @spec update(map()) ::
          {:ok, AppSettingsSchema.t()} | {:error, Changeset.t() | :would_lock_out}
  def update(attrs) when is_map(attrs) do
    case normalise_keys(attrs) do
      {:ok, normalised} -> apply_update(normalised)
      {:error, changeset} -> {:error, changeset}
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
        {:ok, settings}

      {:error, :would_lock_out} = error ->
        Logger.warning("App settings update blocked: would lock out all users",
          keys: Map.keys(attrs)
        )

        error

      {:error, changeset} = error ->
        Logger.warning("App settings update failed", errors: inspect(changeset.errors))
        error
    end
  end

  # Guard callback invoked under the row lock with the merged settings row
  # (the exact state that is about to be committed). Returns `:ok` to allow
  # the commit or `{:error, :would_lock_out}` to roll it back.
  defp lockout_guard(merged_row, attrs) do
    if LockoutPolicy.would_cause_lockout?(merged_row, attrs),
      do: {:error, :would_lock_out},
      else: :ok
  end

  @doc """
  Clears the DB override for `key`, falling back to the config layer or
  built-in default. Convenience wrapper over `update/1`.
  """
  @spec reset(setting_key()) ::
          {:ok, AppSettingsSchema.t()} | {:error, Changeset.t() | :would_lock_out}
  def reset(key) when is_atom(key), do: update(%{key => nil})

  @doc """
  Built-in default for a setting, used when neither the DB nor the
  application config provides a value.
  """
  @spec default_for(setting_key()) :: term()
  defdelegate default_for(key), to: Env

  defp effective_value(key, nil), do: Env.read(key)
  defp effective_value(_key, value), do: value

  defp source_for(key, nil) do
    case Env.baseline_value(key) do
      {:ok, _value} -> :config
      _other -> :default
    end
  end

  defp source_for(_key, _value), do: :db
end
