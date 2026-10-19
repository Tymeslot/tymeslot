defmodule Tymeslot.Release do
  @moduledoc """
  Helpers callable from a packaged release where `mix` is not available.

  `migrate/1`, `strip_upload_metadata/0` and `verify_proxy/1` run in a
  one-shot helper VM, `bin/tymeslot eval`, and need no running node. Every
  other helper acts on the running node and goes through `bin/tymeslot
  rpc`: under `eval` it raises rather than boot a second copy of the
  application (its Oban queues, endpoint and start-up tasks) beside the
  live one. The mix tasks under `Mix.Tasks.Tymeslot.*` delegate here so the
  implementation stays in one place and behaves identically across dev
  (`mix tymeslot.promote_admin`) and production (`bin/tymeslot rpc
  'Tymeslot.Release.promote_admin("…")'`).
  """

  alias Ecto.Migrator
  alias Tymeslot.AppSettings
  alias Tymeslot.AppSettings.AppSettingsSchema
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{AdminRoles, AdminUserQueries, UserQueries, UserSchema}
  alias Tymeslot.Infrastructure.{FinchPool, ProxyVerifier}
  alias Tymeslot.Media.UploadMetadataSweep

  @doc """
  Runs every pending migration of `app`'s repos (its `:ecto_repos`), each
  through `Ecto.Migrator.with_repo/2`, which starts only the repo. Every
  start script runs it before the server starts:

      bin/tymeslot eval 'Tymeslot.Release.migrate()'

  `run_opts` go to `Ecto.Migrator.run/4` beside `all: true`.
  """
  @spec migrate(atom(), keyword()) :: :ok
  def migrate(app \\ :tymeslot, run_opts \\ []) do
    :ok = Application.ensure_loaded(app)
    run_opts = Keyword.put(run_opts, :all, true)

    for repo <- Application.fetch_env!(app, :ecto_repos) do
      {:ok, _migrated, _apps} =
        Migrator.with_repo(repo, &Migrator.run(&1, :up, run_opts))
    end

    :ok
  end

  @doc """
  Promotes the user with the given email to admin.

  Returns:
    * `{:ok, %UserSchema{}}` on success (or if already admin)
    * `{:error, :not_found}` if no user has that email
    * `{:error, :admin_ui_disabled}` if the admin UI is disabled (SaaS)
    * `{:error, changeset}` if the update itself fails
  """
  @spec promote_admin(String.t()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :admin_ui_disabled | Ecto.Changeset.t()}
  def promote_admin(email) when is_binary(email) do
    ensure_running!()

    with {:ok, user} <- UserQueries.get_user_by_email(email) do
      AdminRoles.promote(:cli, user.id)
    end
  end

  @doc """
  Demotes the user with the given email from admin.

  Refuses to demote an admin when no other admin could still sign in, unless
  `force?` is true. The check is `AdminRoles.demote/3`'s own last-admin guard,
  made under the admin row lock, so two operators demoting the last two
  admins at once cannot both succeed. `force?` is the operator escape hatch,
  for instance to remove a compromised sole admin before promoting a
  replacement. `mix tymeslot.demote_admin` and the documented production
  path (`bin/tymeslot rpc 'Tymeslot.Release.demote_admin("…")'`) both come
  through here.
  """
  @spec demote_admin(String.t(), boolean()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :admin_ui_disabled | :last_admin | Ecto.Changeset.t()}
  def demote_admin(email, force? \\ false) when is_binary(email) do
    ensure_running!()

    with :ok <- ensure_admin_ui_enabled(),
         {:ok, user} <- UserQueries.get_user_by_email(email) do
      AdminRoles.demote(:cli, user.id, force: force?)
    end
  end

  @doc """
  Deletes the account with the given email now, bypassing any grace period,
  and waits for the deletion to finish:

      bin/tymeslot rpc 'Tymeslot.Release.delete_account("someone@example.com")'

  Refuses the only remaining admin unless `force?` is true. Returns
  `{:ok, :deleted}`, or the error that stopped the deletion; in that case the
  queued deletion job retries by itself.
  """
  @spec delete_account(String.t(), boolean()) :: {:ok, :deleted} | {:error, term()}
  def delete_account(email, force? \\ false) when is_binary(email) do
    ensure_running!()

    with {:ok, user} <- UserQueries.get_user_by_email(email),
         {:ok, _pending} <-
           Auth.delete_account_now(:cli, user.id, force: force?, job_at: fallback_job_at()) do
      case Auth.run_scheduled_deletion(user.id, force: force?) do
        {:ok, outcome} when outcome in [:deleted, :already_deleted] -> {:ok, :deleted}
        {:ok, outcome} -> {:error, outcome}
        {:snooze, _seconds} -> {:error, :not_due}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The deletion runs synchronously, so the queued job is only the retry if
  # that fails. Queued for now, Oban would race the synchronous run and do
  # the cleanup and the hook twice; on success it finds the account gone.
  defp fallback_job_at, do: DateTime.add(DateTime.utc_now(:second), 5, :minute)

  # Checked here too (rather than relying solely on `AdminRoles.demote/3`'s
  # own check) so a disabled admin UI is reported before an unknown email,
  # the same precedence promote_admin/1 has.
  defp ensure_admin_ui_enabled do
    if AdminRoles.admin_ui_enabled?(), do: :ok, else: {:error, :admin_ui_disabled}
  end

  @doc """
  Lists every admin user (email + id). Useful for operators verifying the
  current state of an install.
  """
  @spec list_admins() :: [%{id: integer(), email: String.t()}]
  def list_admins do
    ensure_running!()

    Enum.map(AdminUserQueries.list_admins(), fn user -> %{id: user.id, email: user.email} end)
  end

  @doc """
  Opens registration, for an install nobody can sign in to: its accounts are
  gone and registration was closed from the admin UI. Sign up, promote the
  new account with `promote_admin/1`, then close registration again from the
  admin UI.

      bin/tymeslot rpc 'Tymeslot.Release.reopen_registration()'

  Refuses when the admin UI is disabled, where registration is not the
  operator's to change, and returns `{:error, {:pinned, :registration_enabled,
  "REGISTRATION_ENABLED"}}` when that environment variable is set, since it
  fixes the setting: set it to `true` and restart instead.
  """
  @spec reopen_registration() ::
          {:ok, AppSettingsSchema.t()}
          | {:error, :admin_ui_disabled | AppSettings.update_error()}
  def reopen_registration do
    ensure_running!()

    with :ok <- ensure_admin_ui_enabled() do
      AppSettings.update(%{registration_enabled: true})
    end
  end

  @doc """
  Strips location, capture time and device metadata from every image and
  video already in the upload directory. See `Tymeslot.Media.UploadMetadataSweep`.

  The sweep runs once by itself after the upgrade that introduced it; this is
  for running it again, for instance after restoring an old uploads backup.

  Touches only files, never the database, so it needs no running node:

      bin/tymeslot eval 'Tymeslot.Release.strip_upload_metadata()'

  Run it as the user the app runs as, so rewritten files keep their owner.
  """
  @spec strip_upload_metadata() :: UploadMetadataSweep.report()
  def strip_upload_metadata, do: UploadMetadataSweep.run()

  @doc """
  Checks that outbound HTTP goes through the configured proxy, and prints a
  report. Returns `:ok` when the proxy carried the test request.

  For a release, where `mix tymeslot.verify_proxy` cannot run:

      bin/tymeslot eval 'Tymeslot.Release.verify_proxy()'
      bin/tymeslot eval 'Tymeslot.Release.verify_proxy(test_url: "https://internal.example/ip")'
      bin/tymeslot eval 'Tymeslot.Release.verify_proxy(quick: true)'

  Runs in the one-shot VM `eval` starts, with only the HTTP client, so it
  does not touch the database or the running node. Options: `:quick` for
  the faster check only, and `ProxyVerifier.verify/1`'s `:test_url` and
  `:timeout`.

  `eval` exits 0 whatever this returns, so the verdict is the last line
  printed, which starts `PASSED:` or `FAILED:`; a script checks that. It
  does not halt with a status of its own: called through `rpc` instead,
  that would stop the running node.
  """
  @spec verify_proxy(keyword()) :: :ok | {:error, term()}
  def verify_proxy(opts \\ []) do
    ensure_http_started()

    if Keyword.get(opts, :quick, false) do
      case ProxyVerifier.quick_check() do
        :ok ->
          IO.puts("PASSED: proxy is working")

        {:error, reason} = error ->
          IO.puts("FAILED: #{reason}")
          error
      end
    else
      result = opts |> Keyword.take([:test_url, :timeout]) |> ProxyVerifier.verify()
      IO.puts(ProxyVerifier.report(result))

      if result.traffic_flows_through_proxy, do: :ok, else: {:error, :proxy_not_verified}
    end
  end

  # These helpers act on the running node (its repo, Oban queues and
  # caches). Under `bin/tymeslot eval` nothing is running, and starting the
  # application there would boot a second copy beside the live node, so
  # they refuse instead. `rpc` and the mix tasks (after `app.start`) run
  # where the application is already up.
  @doc false
  # Public only so the refusal can be tested without stopping the application.
  @spec ensure_running!([{atom(), charlist(), charlist()}]) :: :ok
  def ensure_running!(started \\ Application.started_applications()) do
    unless List.keymember?(started, :tymeslot, 0) do
      raise "Tymeslot.Release needs the running node: use `bin/tymeslot rpc`, not `eval`"
    end

    :ok
  end

  # The proxy check needs only the HTTP client's pool, not the application:
  # starting that in an `eval` VM beside a running node would try to bind
  # the node's port. Under `rpc`, or with the application up, it is there.
  defp ensure_http_started do
    {:ok, _apps} = Application.ensure_all_started(:req)

    if is_nil(Process.whereis(Tymeslot.Finch)) do
      {:ok, _pid} =
        Finch.start_link(name: Tymeslot.Finch, pools: %{default: FinchPool.default_options()})
    end

    :ok
  end
end
