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
      pool_size: parse_int!(env, "DATABASE_POOL_SIZE", @default_pool_size)
    ] ++ tuning_opts()
  end

  def build("docker", env) do
    [
      hostname: Map.get(env, "DATABASE_HOST", "localhost"),
      port: parse_int!(env, "DATABASE_PORT", 5432),
      database: Map.get(env, "POSTGRES_DB", "tymeslot"),
      username: Map.get(env, "POSTGRES_USER", "tymeslot"),
      password: password!(env),
      pool_size: parse_int!(env, "DATABASE_POOL_SIZE", @default_pool_size)
    ] ++ tuning_opts()
  end

  # Connection-pool tuning shared by every deployment type. The defaults suit
  # Oban's concurrency (~47 concurrent workers); ensure PostgreSQL's
  # max_connections stays above :pool_size.
  defp tuning_opts do
    [idle_interval: 60_000, queue_target: 5000, queue_interval: 10_000]
  end

  defp password!(env) do
    Map.get(env, "POSTGRES_PASSWORD") ||
      raise "POSTGRES_PASSWORD environment variable is missing"
  end

  defp parse_int!(env, var, default) do
    case Map.get(env, var) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _other -> raise "Invalid #{var}: #{inspect(value)}. Must be a valid integer."
        end
    end
  end
end
