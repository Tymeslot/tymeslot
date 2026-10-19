defmodule Tymeslot.Release.Encryption do
  @moduledoc """
  Encryption key helpers callable from a packaged release, where `mix` is not
  available:

      bin/tymeslot eval "Tymeslot.Release.Encryption.key_report()"
      bin/tymeslot eval "Tymeslot.Release.Encryption.reencrypt_credentials()"

  `eval` runs in a one-shot VM that starts only the database connection;
  `bin/tymeslot rpc` with the same call runs inside the live node instead. Each
  helper prints a summary and returns the full result. Nothing printed or
  returned ever contains a stored value.
  """

  alias Ecto.Migrator
  alias Tymeslot.Repo
  alias Tymeslot.Security.CredentialReencryption

  @doc """
  How many stored values each key version still holds, per table and column.
  Read-only. Retire the legacy key only once no `v0` values remain, and remove
  a key from `DATA_ENCRYPTION_KEYS` only once none remain under its id. A key
  id that holds values but is no longer configured is named on its own line.
  """
  @spec key_report() :: CredentialReencryption.KeyReport.report()
  def key_report do
    report = with_repo(&CredentialReencryption.key_report/0)

    for {table, columns} <- Enum.sort(report.tables),
        {column, counts} <- Enum.sort(columns),
        counts != %{} do
      IO.puts("#{table}.#{column}: #{format_counts(counts)}")
    end

    IO.puts("total: #{format_counts(report.totals)}")

    for {version, columns} <- Enum.sort(report.missing_keys) do
      IO.puts(
        "key #{version} is not configured but holds values (#{Enum.sum(Map.values(columns))}): " <>
          "add it back under the same id"
      )
    end

    report
  end

  @doc """
  Re-encrypts every stored value under the current primary key. Safe to run
  while the application serves traffic and to re-run: repeat until it reports
  zero migrated values.
  """
  @spec reencrypt_credentials() ::
          {:ok, %{tables: map(), totals: CredentialReencryption.stats()}} | {:error, term()}
  def reencrypt_credentials do
    case with_repo(&CredentialReencryption.run/0) do
      {:ok, %{totals: totals}} = result ->
        IO.puts(
          "migrated values: #{totals.migrated_values}, rows: #{totals.migrated_rows}, " <>
            "already current: #{totals.already_current}, unrecoverable: #{totals.unrecoverable}"
        )

        result

      {:error, :not_configured} = error ->
        IO.puts("No data encryption key is configured, so there is no key to migrate to.")
        error

      error ->
        error
    end
  end

  defp format_counts(counts) when counts == %{}, do: "no values"

  defp format_counts(counts) do
    {unreadable, versions} = Map.pop(counts, :unreadable, 0)

    versions
    |> Enum.sort()
    |> Enum.map(fn {version, count} -> "v#{version} #{count}" end)
    |> Enum.concat(["unreadable #{unreadable}"])
    |> Enum.join(", ")
  end

  # Starts the Repo for an `eval` VM; under `rpc` it is already running and
  # this only runs the function.
  defp with_repo(fun) do
    {:ok, result, _apps} = Migrator.with_repo(Repo, fn _repo -> fun.() end)
    result
  end
end
