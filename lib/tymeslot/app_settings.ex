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
  each key, then pushes any non-nil DB overrides into
  `Application.put_env(:tymeslot, key, value)`. Existing call sites (e.g.
  `Tymeslot.Infrastructure.Config.registration_enabled?/0`) read via
  `Application.get_env/3` and transparently see the DB-backed value without
  any code changes.

  On `update/1`, the same `Application.put_env` push happens, so an admin
  toggling a setting in the UI takes effect immediately — no restart needed.
  Clearing an override (passing `nil`) restores the snapshotted config value.

  Settings are intentionally typed columns rather than a generic key/value
  store: it keeps the migration path explicit, makes the Settings API
  type-safe, and lets the LiveView render each setting with the right control.
  """

  require Logger

  alias Tymeslot.AppSettings.{AppSettingsQueries, AppSettingsSchema}

  @type setting_key :: :registration_enabled | :password_auth_enabled
  @type effective_source :: :db | :config | :default
  @type effective_value :: %{value: term(), source: effective_source(), db_value: term() | nil}

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
  Returns a map of `key -> %{value, source, db_value}` for every editable
  setting. `value` is the effective value an admin would see; `source` shows
  whether it came from the DB, the config layer, or the built-in default.
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
         db_value: db_value
       }}
    end)
  end

  @doc """
  Updates one or more settings. Pass `nil` for a key to clear the DB override
  and fall back to the config/default. The new values are pushed to
  `Application.put_env` on success so the change takes effect immediately.
  """
  @spec update(map()) :: {:ok, AppSettingsSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(attrs) when is_map(attrs) do
    case AppSettingsQueries.update_settings(attrs) do
      {:ok, settings} ->
        Enum.each(keys(), fn key -> apply_override(key, Map.get(settings, key)) end)
        Logger.info("App settings updated", keys: Map.keys(attrs))
        {:ok, settings}

      {:error, changeset} = error ->
        Logger.warning("App settings update failed", errors: inspect(changeset.errors))
        error
    end
  end

  @doc """
  Clears the DB override for `key`, falling back to the config layer or
  built-in default. Convenience wrapper over `update/1`.
  """
  @spec reset(setting_key()) :: {:ok, AppSettingsSchema.t()} | {:error, Ecto.Changeset.t()}
  def reset(key) when is_atom(key), do: update(%{key => nil})

  @doc """
  Built-in default for a setting, used when neither the DB nor the
  application config provides a value.
  """
  @spec default_for(setting_key()) :: term()
  def default_for(:registration_enabled), do: true
  def default_for(:password_auth_enabled), do: true

  # Baseline = the config-layer value that was in effect before any DB
  # override was applied. Captured once per BEAM lifetime in `:persistent_term`
  # (purpose-built for read-heavy, write-rare configuration data) so reset/1
  # can restore the original config value.
  @baseline_sentinel :__app_settings_baseline_not_captured__

  defp capture_baseline(key) do
    term = baseline_term(key)

    case :persistent_term.get(term, @baseline_sentinel) do
      @baseline_sentinel -> :persistent_term.put(term, Application.fetch_env(:tymeslot, key))
      _existing -> :ok
    end
  end

  defp apply_override(key, nil), do: restore_baseline(key)
  defp apply_override(key, value), do: Application.put_env(:tymeslot, key, value)

  defp restore_baseline(key) do
    case :persistent_term.get(baseline_term(key), @baseline_sentinel) do
      {:ok, value} -> Application.put_env(:tymeslot, key, value)
      :error -> Application.delete_env(:tymeslot, key)
      @baseline_sentinel -> :ok
    end
  end

  defp effective_value(key, nil), do: Application.get_env(:tymeslot, key, default_for(key))
  defp effective_value(_key, value), do: value

  defp source_for(key, nil) do
    case :persistent_term.get(baseline_term(key), @baseline_sentinel) do
      {:ok, _value} -> :config
      _other -> :default
    end
  end

  defp source_for(_key, _value), do: :db

  defp baseline_term(key), do: {__MODULE__, :baseline, key}
end
