defmodule Tymeslot.Infrastructure.DatabaseConfig do
  @moduledoc """
  Builds the `Tymeslot.Repo` configuration for a deployment type.

  Called from `config/runtime.exs`, which passes `System.get_env/0` in as the
  environment map. Keeping the mapping here (rather than inline in the config
  file) makes it unit-testable: `config/runtime.exs` is never evaluated under
  `mix test`, so logic living there cannot be asserted on at all.

  ## Deployment types

  - `"cloudron"` — reads the `CLOUDRON_POSTGRESQL_*` variables the platform injects.
  - `"docker"` — reads the discrete `DATABASE_*` / `POSTGRES_*` variables. This is
    also the fallback for every other deployment target (Railway, bare release).

  ## Precedence

  Ecto pops `:url`, parses it, and merges the result **over** the remaining
  options (`Ecto.Repo.Supervisor.init_config/4`). So when `DATABASE_URL` is set,
  its host, port, database, username, and password win over the discrete
  variables — which is what an operator pasting a provider-issued URL expects.
  """

  # Used directly by "cloudron", whose start.sh never exports DATABASE_POOL_SIZE.
  # "docker" never actually falls back to it: start-docker.sh always exports
  # DATABASE_POOL_SIZE (defaulting to 10) before invoking the release, so this
  # value is dead for that deployment type but kept as the documented default
  # should that export ever be dropped.
  @default_pool_size 60

  @type env :: %{optional(String.t()) => String.t()}

  @doc """
  Builds the keyword list for `config :tymeslot, Tymeslot.Repo`.

  ## Raises

  - `RuntimeError` when the Docker deployment has no password source at all,
    or when an integer variable does not hold a valid value.
  """
  @spec build(String.t(), env()) :: keyword()
  def build("cloudron", env) do
    [
      url: env["CLOUDRON_POSTGRESQL_URL"],
      username: env["CLOUDRON_POSTGRESQL_USERNAME"],
      password: env["CLOUDRON_POSTGRESQL_PASSWORD"],
      hostname: env["CLOUDRON_POSTGRESQL_HOST"],
      port: env["CLOUDRON_POSTGRESQL_PORT"],
      database: env["CLOUDRON_POSTGRESQL_DATABASE"],
      pool_size: parse_int!(env, "DATABASE_POOL_SIZE", @default_pool_size, 1)
    ] ++ tuning_opts()
  end

  def build("docker", env) do
    url = blank_to_nil(env["DATABASE_URL"])

    [
      hostname: Map.get(env, "DATABASE_HOST", "localhost"),
      port: parse_int!(env, "DATABASE_PORT", 5432, 1, 65_535),
      database: Map.get(env, "POSTGRES_DB", "tymeslot"),
      username: Map.get(env, "POSTGRES_USER", "tymeslot"),
      password: password!(env, url),
      pool_size: parse_int!(env, "DATABASE_POOL_SIZE", @default_pool_size, 1)
    ] ++ url_opts(url) ++ ssl_opts(env) ++ tuning_opts()
  end

  defp url_opts(nil), do: []
  defp url_opts(url), do: [url: url]

  # Postgrex treats `ssl: true` as "secure defaults" (peer verification plus
  # hostname checking) and merges a keyword list on top of those same defaults,
  # so we never assemble :ssl options by hand.
  defp ssl_opts(env) do
    case env |> Map.get("DATABASE_SSL") |> blank_to_nil() |> normalise_ssl_mode() do
      :off -> []
      :verify -> [ssl: cacert_opts(env)]
      :no_verify -> [ssl: [verify: :verify_none]]
    end
  end

  defp normalise_ssl_mode(nil), do: :off

  defp normalise_ssl_mode(value) do
    case String.downcase(value) do
      mode when mode in ~w(false disable) ->
        :off

      mode when mode in ~w(true verify-full) ->
        :verify

      "verify-none" ->
        :no_verify

      other ->
        raise "Invalid DATABASE_SSL: #{inspect(other)}. " <>
                "Use true, verify-full, verify-none, or false."
    end
  end

  defp cacert_opts(env) do
    case blank_to_nil(env["DATABASE_SSL_CACERT_FILE"]) do
      nil ->
        true

      path ->
        unless File.regular?(path) do
          raise "Invalid DATABASE_SSL_CACERT_FILE: #{inspect(path)} does not exist or is not a readable file."
        end

        [cacertfile: path]
    end
  end

  # Connection-pool tuning shared by every deployment type. The :oban_queues
  # concurrencies in config/config.exs currently sum to 68 concurrent workers;
  # ensure PostgreSQL's max_connections stays above :pool_size.
  defp tuning_opts do
    [idle_interval: 60_000, queue_target: 5000, queue_interval: 10_000]
  end

  # With DATABASE_URL set, the password rides along inside it and Ecto merges it
  # over this nil. Without either, there is no way to reach any database, so fail
  # at boot with a message naming both escape hatches.
  defp password!(_env, url) when is_binary(url), do: nil

  defp password!(env, nil) do
    Map.get(env, "POSTGRES_PASSWORD") ||
      raise """
      No database password configured.

      Set POSTGRES_PASSWORD, or set DATABASE_URL to a full connection string
      such as postgres://user:password@host:5432/database
      """
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Shared by every bounded env-var integer (port, pool size) so each caller
  # only states its own valid range instead of re-implementing the parsing.
  defp parse_int!(env, var, default, min, max \\ nil) do
    case Map.get(env, var) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} -> validate_int_range!(var, int, min, max)
          _other -> raise "Invalid #{var}: #{inspect(value)}. Must be a valid integer."
        end
    end
  end

  defp validate_int_range!(_var, int, min, max) when int >= min and (is_nil(max) or int <= max),
    do: int

  defp validate_int_range!(var, int, min, nil) do
    raise "Invalid #{var}: #{int}. Must be #{min} or greater."
  end

  defp validate_int_range!(var, int, min, max) do
    raise "Invalid #{var}: #{int}. Must be between #{min} and #{max}."
  end
end
