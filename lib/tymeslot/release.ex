defmodule Tymeslot.Release do
  @moduledoc """
  Helpers callable from a packaged release where `mix` is not available.

  `migrate/1`, `strip_upload_metadata/0`, `verify_proxy/1` and
  `backfill_dispute_losses/1` run in a one-shot helper VM, `bin/tymeslot
  eval`, and need no running node. Every other helper acts on the running
  node and goes through `bin/tymeslot rpc`: under `eval` it raises rather
  than boot a second copy of the application (its Oban queues, endpoint
  and start-up tasks) beside the live one. The mix tasks under
  `Mix.Tasks.Tymeslot.*` delegate here so the implementation stays in one
  place and behaves identically across dev (`mix tymeslot.promote_admin`)
  and production (`bin/tymeslot rpc 'Tymeslot.Release.promote_admin("…")'`).
  """

  alias Ecto.Migrator
  alias Tymeslot.AppSettings
  alias Tymeslot.AppSettings.AppSettingsSchema
  alias Tymeslot.Auth.AccountDeletion
  alias Tymeslot.Auth.{AdminRoles, AdminUserQueries, UserQueries, UserSchema}
  alias Tymeslot.Infrastructure.{FinchPool, ProxyVerifier}
  alias Tymeslot.Integrations.Stripe
  alias Tymeslot.Media.UploadMetadataSweep
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.DisputeLossBackfill
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.Repo

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
           AccountDeletion.delete_account_now(:cli, user.id,
             force: force?,
             job_at: fallback_job_at()
           ) do
      case AccountDeletion.run_scheduled_deletion(user.id, force: force?) do
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

  @doc """
  Corrects the refund figures of booking payments whose dispute was lost
  before the refunds made had a column of their own, from what Stripe
  records. Until it runs, a payment whose dispute was lost before 1.48.0
  counts the loss as refunds made at Stripe, and one refunded before the
  loss holds too small a refunded total, so the host may refund more than
  is left; one refunded and then lost over the same money since shows the
  refunds as fewer than were made, down to none. For each payment with a
  lost dispute it sets the refunds made (`stripe_refunded_cents`) from the
  charge, records the dispute's share (`disputed_lost_cents`), and sets the
  refunded total and status to what the two give (never lower than
  before); it changes nothing else on the row. Run it once on a deployment
  that took payments before the refunds had their column; a dry run first
  shows what it would change:

      bin/tymeslot eval 'Tymeslot.Release.backfill_dispute_losses()'                  # dry run
      bin/tymeslot eval 'Tymeslot.Release.backfill_dispute_losses(dry_run: false)'    # write

  Under `eval` it starts only the repo and the HTTP client, as `migrate/1`
  and `verify_proxy/1` do; through `rpc` it uses the running node's. It
  makes one or two Stripe calls per candidate payment (its disputes, and
  its charge when one was lost), `:pause_ms` (default 100) apart; `:limit`
  caps how many are read. The candidates
  (`Tymeslot.MeetingPayments.DisputeLossBackfill`) can be counted first:

      SELECT count(*) FROM booking_payments AS b
      WHERE stripe_charge_id IS NOT NULL
        AND ((disputed_lost_cents = 0 AND refunded_amount_cents > 0
              AND status IN ('refunded', 'partially_refunded')
              AND b.inserted_at < (SELECT inserted_at FROM schema_migrations
                                   WHERE version = 20261120141652)
              AND (stripe_dispute_id IS NOT NULL
                   OR b.inserted_at < (SELECT inserted_at FROM schema_migrations
                                       WHERE version = 20261103142458)))
          OR (disputed_lost_cents > 0
              AND stripe_refunded_cents + disputed_lost_cents = amount_cents
              AND b.inserted_at < (SELECT inserted_at FROM schema_migrations
                                   WHERE version = 20261124084318)));

  It prints a line per payment corrected (or, in a dry run, to be
  corrected) with the payment id, charge id, lost cents, and the refunds
  made and the refunded total before and after, a line per failed Stripe
  call, and a summary. Running it again is safe: it writes nothing to a
  payment whose figures already match Stripe's, though it reads again
  those whose refunds and loss add up to exactly the amount paid. `eval` exits 0 whatever this returns, so the verdict is
  the last line printed, which starts `DRY RUN:` or `DONE:`, or `FAILED:`
  when no Stripe secret key is configured and nothing was read.
  """
  @spec backfill_dispute_losses(keyword()) :: :ok | {:error, :missing_api_key}
  def backfill_dispute_losses(opts \\ []) do
    if Stripe.configured?() do
      dry_run? = Keyword.get(opts, :dry_run, true)
      ensure_http_started()

      summary =
        with_repo(fn ->
          opts
          |> Keyword.put(:dry_run, dry_run?)
          |> Keyword.put(:on_outcome, &print_dispute_loss/1)
          |> DisputeLossBackfill.run()
        end)

      IO.puts(dispute_loss_summary(summary, dry_run?))
    else
      IO.puts("FAILED: no Stripe secret key is configured (STRIPE_SECRET_KEY); nothing was read")
      {:error, :missing_api_key}
    end
  end

  defp print_dispute_loss({:error, payment, reason}),
    do: IO.puts("ERROR #{payment.id} #{payment.stripe_charge_id}: #{error_text(reason)}")

  defp print_dispute_loss({written, payment, correction}) do
    IO.puts(
      "#{dispute_loss_label(written)} #{payment.id} #{payment.stripe_charge_id} " <>
        "lost #{correction.disputed_lost_cents}, refunds made " <>
        "#{payment.stripe_refunded_cents} -> #{correction.stripe_refunded_cents}, refunded " <>
        "#{payment.refunded_amount_cents} -> #{correction.refunded_amount_cents}"
    )
  end

  defp dispute_loss_label(:recorded), do: "CORRECTED"
  defp dispute_loss_label(:would_record), do: "WOULD CORRECT"
  defp dispute_loss_label(:unchanged), do: "CHANGED MEANWHILE"

  defp error_text(%{__exception__: true} = error), do: Exception.message(error)
  defp error_text(reason), do: inspect(reason)

  defp dispute_loss_summary(summary, dry_run?) do
    counts =
      "#{summary.candidates} candidates, #{summary.lost} with a lost dispute to correct, " <>
        "#{summary.clamped} clamped to the amount paid, #{length(summary.errors)} errors"

    if dry_run? do
      "DRY RUN: #{counts}; nothing written, run with dry_run: false to correct"
    else
      "DONE: #{counts}; #{summary.updated} corrected, #{summary.unchanged} changed meanwhile"
    end
  end

  @doc """
  Records how a refund ended that Tymeslot cannot ask Stripe about, once
  an operator has looked at its charge in Stripe's dashboard. Such a
  refund (a `:refund_stuck` alert names it) stays pending: Stripe refuses
  to list the charge's refunds, as when the host revoked the Connect
  account, so every attempt leaves it so, its amount stays held against
  what may still be refunded, and the host sees it as being processed.

  If Stripe made the refund, give its id and the charge's refunded total
  as the dashboard shows it, in cents (`amount_refunded`, this refund
  included); if Stripe never made it, or it failed there, give `:failed`:

      bin/tymeslot rpc 'Tymeslot.Release.settle_stuck_refund("<refund id>", {:succeeded, "re_…", 2500})'
      bin/tymeslot rpc 'Tymeslot.Release.settle_stuck_refund("<refund id>", :failed)'

  It settles the refund as a Stripe report would
  (`Tymeslot.MeetingPayments.Refunds.Settlement.settle_by_hand/2`), under
  the same locks, so a webhook arriving meanwhile cannot settle it twice:
  made, the payment's figures and status are raised and the attendee is
  emailed; failed, the figures stay as they are and the admins and the
  host are told the attendee is still owed the money. It runs on the
  live node, since those emails and alerts go through its job queue.

  It prints the refund and its payment's figures before and after, and a
  last line starting `SETTLED:`, or `REFUSED:` with the reason when
  nothing was written: an unknown refund, one not pending, one an attempt
  is making now, or a malformed outcome.
  """
  @spec settle_stuck_refund(String.t(), term()) :: {:ok, RefundSchema.t()} | {:error, term()}
  def settle_stuck_refund(refund_id, outcome) do
    ensure_running!()

    case RefundQueries.get(refund_id) do
      nil ->
        IO.puts("REFUSED: no refund has id #{inspect(refund_id)}")
        {:error, :not_found}

      refund ->
        payment = BookingPaymentQueries.get(refund.booking_payment_id)
        print_refund("BEFORE", refund, payment)

        refund
        |> Refunds.settle_by_hand(outcome)
        |> settled_by_hand(refund, payment, outcome)
    end
  end

  defp settled_by_hand({:ok, settled, written}, _refund, payment, _outcome) do
    print_refund("AFTER", settled, BookingPaymentQueries.get(payment.id))

    case written do
      :settled ->
        IO.puts("SETTLED: refund #{settled.id} is #{settled.status}")
        {:ok, settled}

      :already_settled ->
        IO.puts("REFUSED: refund #{settled.id} was settled meanwhile; nothing written")
        {:error, :not_pending}
    end
  end

  defp settled_by_hand({:error, reason} = error, refund, payment, outcome) do
    IO.puts("REFUSED: " <> refusal_text(reason, refund, payment, outcome))
    error
  end

  defp refusal_text(:not_pending, refund, _payment, _outcome),
    do: "refund #{refund.id} is #{refund.status}, not pending; nothing written"

  defp refusal_text(:attempt_in_flight, refund, _payment, _outcome),
    do:
      "an attempt at refund #{refund.id} is under way; run this again once it has ended " <>
        "(within five minutes) if the refund is still pending"

  defp refusal_text(:invalid_outcome, _refund, _payment, outcome),
    do:
      "#{inspect(outcome)} is not an outcome: give " <>
        ~s|{:succeeded, "re_…", charge_refunded_cents} or :failed|

  defp refusal_text(:charge_total_out_of_range, refund, payment, _outcome),
    do:
      "the charge's refunded total includes this refund, so it is between " <>
        "#{refund.amount_cents} and #{payment.amount_cents} (cents, Stripe's amount_refunded)"

  defp refusal_text(:stripe_refund_taken, _refund, _payment, {:succeeded, stripe_id, _total}),
    do: "Stripe refund #{stripe_id} is already recorded on another refund"

  defp refusal_text(reason, _refund, _payment, _outcome), do: error_text(reason)

  defp print_refund(label, refund, payment) do
    IO.puts(
      "#{label} refund #{refund.id} #{refund.status} (#{refund.source}): " <>
        "#{refund.amount_cents} cents, attempt #{refund.attempt}, " <>
        "stripe refund #{refund.stripe_refund_id || "none"}, " <>
        "failure code #{refund.failure_code || "none"}"
    )

    IO.puts(
      "#{label} payment #{payment.id} #{payment.status} (#{payment.currency}): " <>
        "refunds made #{payment.stripe_refunded_cents}, lost in dispute " <>
        "#{payment.disputed_lost_cents}, refunded #{payment.refunded_amount_cents} " <>
        "of #{payment.amount_cents}"
    )
  end

  # With the application up (`rpc`, mix, tests) the repo is already running,
  # and `Ecto.Migrator.with_repo/2` would restart its pool afterwards; under
  # `eval` it starts the repo alone, as `migrate/2` does.
  defp with_repo(fun) do
    if List.keymember?(Application.started_applications(), :tymeslot, 0) do
      fun.()
    else
      {:ok, result, _apps} = Migrator.with_repo(Repo, fn _repo -> fun.() end)
      result
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
