defmodule Mix.Tasks.Tymeslot.ReencryptCredentials do
  @moduledoc """
  Re-encrypts stored credentials under the current data-at-rest key.

  After `DATA_ENCRYPTION_KEY` is configured, existing credentials are still stored
  under the legacy `SECRET_KEY_BASE`-derived key. This task walks every encrypted
  column across the integration tables and rewrites each value with the new
  primary key, so the two secrets become fully independent.

  The sweep is idempotent and resumable: values already stored under the current
  key are skipped, so it is safe to run repeatedly and to re-run after an
  interruption. Values that cannot be decrypted under any available key are
  reported as `unrecoverable` and left untouched — they continue through the
  normal reconnection (`needs_reauth`) flow.

  ## Usage

      mix tymeslot.reencrypt_credentials
      mix tymeslot.reencrypt_credentials --batch-size 500

  Re-run until the reported `migrated_values` is `0` to confirm the sweep is
  complete. Only then is it safe to retire the legacy key (a future release).

  Requires `DATA_ENCRYPTION_KEY` to be set; the task aborts otherwise, since there
  would be no primary key to migrate to.
  """

  use Mix.Task

  alias Tymeslot.Security.CredentialReencryption

  @shortdoc "Re-encrypt stored credentials under the current DATA_ENCRYPTION_KEY"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [batch_size: :integer])

    Mix.Task.run("app.start")

    case CredentialReencryption.run(opts) do
      {:ok, result} ->
        print_report(result)

      {:error, :not_configured} ->
        Mix.raise("""
        DATA_ENCRYPTION_KEY is not configured — there is no primary key to migrate to.

        Set it (e.g. `openssl rand -base64 48`) in the environment, redeploy so the
        app writes new values under it, then run this task.
        """)

      {:error, {:invalid_batch_size, value}} ->
        Mix.raise("--batch-size must be a positive integer, got: #{inspect(value)}.")
    end
  end

  defp print_report(%{tables: tables, totals: totals}) do
    Mix.shell().info("Credential re-encryption sweep complete.\n")

    Enum.each(tables, fn {table, stats} -> Mix.shell().info(format_line(table, stats)) end)

    Mix.shell().info("\n" <> format_line("TOTAL", totals))

    if totals.unrecoverable > 0 do
      Mix.shell().info(
        "\n#{totals.unrecoverable} value(s) could not be decrypted and were left unchanged; " <>
          "the affected integrations will prompt the user to reconnect."
      )
    end

    if totals.migrated_values > 0 do
      Mix.shell().info(
        "\nRe-run this task until `migrated` is 0 to confirm every value is on the current key."
      )
    else
      Mix.shell().info("\nNo values needed migration — all credentials are on the current key.")
    end
  end

  defp format_line(label, stats) do
    "#{String.pad_trailing(label, 24)} " <>
      "migrated=#{stats.migrated_values} " <>
      "rows=#{stats.migrated_rows} " <>
      "already_current=#{stats.already_current} " <>
      "unrecoverable=#{stats.unrecoverable}"
  end
end
