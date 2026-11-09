defmodule Tymeslot.EmailSending.DeliveryStatusTest do
  @moduledoc "Verifies sanitized, revision-scoped SMTP health reporting and actual delivery hooks."

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :integration

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Test.ClockHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Changeset
  alias Oban.Job
  alias Swoosh.Email
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.{DeliveryStatus, Sender, Settings, UserSmtpSettingsSchema}
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.FakeSmtpRelay
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.DeliveryClaims.DeliveryClaimSchema
  alias Tymeslot.Workers.EmailWorker

  @now ~U[2026-11-09 12:00:00.000000Z]

  defmodule Destination do
    @moduledoc false
    @behaviour Tymeslot.EmailSending.Destination

    @impl Tymeslot.EmailSending.Destination
    def resolve(_host, _port) do
      {:ok,
       %{address: {127, 0, 0, 1}, port: Application.fetch_env!(:tymeslot, :smtp_status_test_port)}}
    end
  end

  setup_all do
    %{certificates: FakeSmtpRelay.certificates(~c"smtp.example.com")}
  end

  setup %{certificates: certificates} do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      user_smtp_destination_module: Destination,
      user_smtp_cacertfile: certificates.cacertfile
    )

    freeze_clock(@now)
    owner = insert(:user)
    settings = settings(owner)
    %{owner: owner, settings: settings, sender: Sender.from_settings(settings)}
  end

  test "only fixed codes leave status classification and public settings", context do
    for code <-
          ~w(authentication_failed tls_required dns_failed invalid_destination
             credentials_unavailable invalid_settings not_tested session_timeout
             ambiguous_timeout delivery_failed) do
      assert DeliveryStatus.sanitize(code) == code
    end

    assert DeliveryStatus.sanitize(nil) == nil
    assert DeliveryStatus.sanitize("raw-relay-password-secret") == "delivery_failed"

    assert DeliveryStatus.outcome({:error, {:provider, "raw-relay-password-secret"}}) ==
             {:failure, "delivery_failed"}

    public = Settings.from_schema(%{context.settings | last_error: "raw-relay-password-secret"})
    assert public.last_error == "delivery_failed"
    refute inspect(public) =~ "raw-relay-password-secret"
  end

  test "recording an account failure leaves the tested identity and configuration timestamps intact",
       context do
    assert :ok =
             EmailSending.record_delivery_outcome(
               context.sender,
               {:error, :authentication_failed}
             )

    current = Repo.reload!(context.settings)
    assert current.last_error == "authentication_failed"
    assert current.last_failed_at == @now
    assert current.revision == context.settings.revision
    assert current.tested_revision == context.settings.tested_revision
    assert current.tested_at == context.settings.tested_at
    assert current.updated_at == context.settings.updated_at
    assert {:ok, _credentials} = EmailSending.delivery_credentials(context.sender)
  end

  test "identical failures coalesce for five minutes while a changed reason appears immediately",
       context do
    report(context.sender, :authentication_failed)

    freeze_clock(DateTime.add(@now, 60, :second))
    report(context.sender, :authentication_failed)
    assert Repo.reload!(context.settings).last_failed_at == @now

    changed_at = DateTime.add(@now, 61, :second)
    freeze_clock(changed_at)
    report(context.sender, :dns_failed)
    assert Repo.reload!(context.settings).last_failed_at == changed_at

    freeze_clock(DateTime.add(changed_at, 299, :second))
    report(context.sender, :dns_failed)
    assert Repo.reload!(context.settings).last_failed_at == changed_at

    refreshed_at = DateTime.add(changed_at, 300, :second)
    freeze_clock(refreshed_at)
    report(context.sender, :dns_failed)
    assert Repo.reload!(context.settings).last_failed_at == refreshed_at
  end

  test "real relay acceptance clears status without invalidating the sender revision", context do
    report(context.sender, :dns_failed)
    assert :ok = EmailSending.record_delivery_outcome(context.sender, {:ok, :accepted})

    current = Repo.reload!(context.settings)
    assert current.last_error == nil
    assert current.last_failed_at == nil
    assert current.revision == context.sender.revision
    assert current.tested_revision == context.sender.revision
    assert {:ok, _credentials} = EmailSending.delivery_credentials(context.sender)
  end

  test "recipient, capacity and infrastructure refusals do not overwrite or clear account health",
       context do
    report(context.sender, :authentication_failed)

    for ignored <- [
          {:error, :recipient_rejected},
          {:error, {:recipient_rejected, %{reason: "raw-relay-password-secret"}}},
          {:error, :rate_limited},
          {:error, :circuit_open},
          {:error, :breaker_unavailable},
          {:error, :connection_unavailable},
          {:error, :settings_changed},
          {:error, :feature_disabled},
          {:ok, :assumed_delivered},
          :ok
        ] do
      assert :ok = EmailSending.record_delivery_outcome(context.sender, ignored)
    end

    current = Repo.reload!(context.settings)
    assert current.last_error == "authentication_failed"
    assert current.last_failed_at == @now
  end

  test "a foreign owner, row or From identity cannot update a settings record", context do
    foreign = insert(:user)
    other = settings(foreign)

    for forged <- [
          %{context.sender | owner_id: foreign.id},
          %{context.sender | settings_id: other.id},
          %{context.sender | from_address: "foreign@example.com"},
          %{context.sender | from_name: "Foreign brand"}
        ] do
      report(forged, :authentication_failed)
    end

    assert Repo.reload!(context.settings) == context.settings
    assert Repo.reload!(other) == other
  end

  test "an old revision cannot record a failure or clear a repaired revision's status", context do
    current =
      context.settings
      |> Changeset.change(
        revision: 2,
        tested_revision: 2,
        last_error: "dns_failed",
        last_failed_at: @now
      )
      |> Repo.update!()

    report(context.sender, :authentication_failed)
    assert :ok = EmailSending.record_delivery_outcome(context.sender, {:ok, :accepted})
    assert Repo.reload!(current) == current
  end

  for state <- [:disabled, :untested, :deleted] do
    test "a #{state} configuration cannot receive status updates from an old execution",
         context do
      case unquote(state) do
        :disabled ->
          Repo.update!(Changeset.change(context.settings, enabled: false))

        :untested ->
          Repo.update!(Changeset.change(context.settings, enabled: false, tested_revision: nil))

        :deleted ->
          Repo.delete!(context.settings)
      end

      before = Repo.get(UserSmtpSettingsSchema, context.settings.id)
      report(context.sender, :authentication_failed)
      assert Repo.get(UserSmtpSettingsSchema, context.settings.id) == before
    end
  end

  test "deleting and recreating settings cannot reuse status from an old record", context do
    Repo.delete!(context.settings)
    replacement = settings(context.owner)
    assert replacement.revision == context.sender.revision
    refute replacement.id == context.sender.settings_id

    report(context.sender, :authentication_failed)
    assert Repo.reload!(replacement) == replacement
  end

  test "unknown outcome data becomes a generic code and cannot leak through status", context do
    report(context.sender, {"raw-relay-password-secret", %{password: "smtp-password-secret"}})

    assert {:ok, public} = EmailSending.get_settings(context.owner)
    assert public.last_error == "delivery_failed"
    refute :erlang.term_to_binary(public) =~ "raw-relay-password-secret"
    refute :erlang.term_to_binary(public) =~ "smtp-password-secret"
  end

  test "invalid and unavailable status operations fail closed without exposing exceptions",
       context do
    log =
      capture_log(fn ->
        assert :ok =
                 EmailSending.record_delivery_outcome(
                   %{context.sender | from_address: nil},
                   {:error, "raw-relay-password-secret"}
                 )

        for invalid <- [nil, %{}, Sender.platform(), %{context.sender | owner_id: -1}] do
          assert :ok = EmailSending.record_delivery_outcome(invalid, {:error, :delivery_failed})
        end
      end)

    assert log =~ "User SMTP delivery status unavailable"
    refute log =~ "raw-relay-password-secret"
    assert Repo.reload!(context.settings) == context.settings
  end

  test "actual SMTP failures and recovery update the owner status without changing outcomes",
       context do
    use_relay(context.certificates, auth: :reject)

    assert {:error, :authentication_failed} =
             Delivery.deliver(email(context.sender), sender: context.sender)

    assert Repo.reload!(context.settings).last_error == "authentication_failed"

    use_relay(context.certificates)
    assert {:ok, :accepted} = Delivery.deliver(email(context.sender), sender: context.sender)
    assert Repo.reload!(context.settings).last_error == nil
    assert_receive {:smtp_relay, {:message, _body}}
  end

  test "unreadable credentials report attention before any socket is opened", context do
    context.settings
    |> Changeset.change(password_encrypted: "unreadable ciphertext")
    |> Repo.update!()

    assert {:error, :credentials_unavailable} =
             Delivery.deliver(email(context.sender), sender: context.sender)

    assert Repo.reload!(context.settings).last_error == "credentials_unavailable"
    refute_received {:smtp_relay, _event}
  end

  test "ambiguous transport timeout remains attention-required when delivery policy assumes success",
       context do
    use_relay(context.certificates, after_data: :silent)
    with_config(:tymeslot, email_send_deadline_ms: 1_000)

    assert {{:ok, :assumed_delivered}, false} =
             Delivery.with_ambiguous_timeouts(:assume_delivered, fn ->
               Delivery.deliver(email(context.sender), sender: context.sender)
             end)

    assert Repo.reload!(context.settings).last_error == "ambiguous_timeout"
    assert_receive {:smtp_relay, {:message, _body}}
  end

  test "a successful replacement test clears failure and advances only the tested configuration",
       context do
    report(context.sender, :authentication_failed)
    use_relay(context.certificates)

    assert {:ok, updated} =
             EmailSending.test_and_save_settings(
               context.owner,
               %{},
               Settings.version(Settings.from_schema(context.settings))
             )

    assert updated.last_error == nil
    assert updated.last_failed_at == nil
    assert updated.revision == context.settings.revision + 1
    assert updated.tested_revision == updated.revision
    assert updated.enabled
  end

  test "a successful retest clears failures recorded while its SMTP transaction was in progress",
       context do
    reference = make_ref()
    use_relay(context.certificates, after_data: {:await, reference})

    pending =
      Tasks.async_nolink(Tymeslot.TaskSupervisor, fn ->
        EmailSending.test_and_save_settings(
          context.owner,
          %{},
          {context.settings.id, context.settings.revision}
        )
      end)

    assert_receive {:smtp_relay, {:awaiting_ack, relay, ^reference}}, 2_000
    report(context.sender, :authentication_failed)
    assert Repo.reload!(context.settings).last_error == "authentication_failed"
    send(relay, {:ack, reference})

    assert {:ok, updated} = Task.await(pending, 2_000)
    assert updated.last_error == nil
    assert updated.last_failed_at == nil
    assert updated.revision == context.settings.revision + 1
  end

  test "a locked status row cannot hold an accepted SMTP copy or prevent its durable claim",
       context do
    use_relay(context.certificates)

    with_connection_pool(2, fn pool ->
      owner = insert(:user)
      on_exit(fn -> delete_committed_user(owner.id) end)

      settings =
        owner
        |> settings()
        |> Changeset.change(last_error: "authentication_failed", last_failed_at: @now)
        |> Repo.update!()

      sender = Sender.from_settings(settings)

      job =
        %{"action" => "send_no_password_to_reset", "user_id" => owner.id}
        |> EmailWorker.new()
        |> Oban.insert!()

      on_exit(fn -> delete_committed_job(job.id) end)

      holder =
        hold_connection(pool, fn ->
          Repo.one!(
            from(s in UserSmtpSettingsSchema, where: s.id == ^settings.id, lock: "FOR UPDATE")
          )
        end)

      try do
        started = System.monotonic_time(:millisecond)

        log =
          capture_log(fn ->
            assert {:ok, :accepted} =
                     DeliveryClaims.once(job.id, "accepted_copy", fn ->
                       Delivery.deliver(email(sender), sender: sender)
                     end)
          end)

        assert System.monotonic_time(:millisecond) - started < 2_000
        assert log =~ "User SMTP delivery status unavailable"
        refute log =~ "smtp-password-secret"
        assert_receive {:smtp_relay, {:message, _body}}

        assert :ok =
                 DeliveryClaims.once(job.id, "accepted_copy", fn ->
                   flunk("An accepted, claimed copy must never be sent again")
                 end)

        assert Repo.reload!(settings).last_error == "authentication_failed"
      after
        release_connection(holder)
      end
    end)
  end

  test "status reporting refuses a saturated pool instead of waiting for a connection", context do
    with_connection_pool(1, fn pool ->
      holder = hold_connection(pool, fn -> Repo.query!("SELECT 1") end)

      try do
        started = System.monotonic_time(:millisecond)

        log =
          capture_log(fn ->
            assert :ok =
                     EmailSending.record_delivery_outcome(context.sender, {:error, :dns_failed})
          end)

        assert System.monotonic_time(:millisecond) - started < 1_000
        assert log =~ "User SMTP delivery status unavailable"
      after
        release_connection(holder)
      end
    end)

    assert Repo.reload!(context.settings) == context.settings
  end

  defp report(sender, reason) do
    assert :ok = EmailSending.record_delivery_outcome(sender, {:error, reason})
  end

  # A real connection pool keeps a deliberate statement timeout from poisoning
  # the test's sandbox transaction and exercises production checkout behavior.
  defp with_connection_pool(size, run) do
    options =
      Keyword.merge(Repo.config(), name: nil, pool: DBConnection.ConnectionPool, pool_size: size)

    pool = start_supervised!({Repo, options})
    previous = Repo.put_dynamic_repo(pool)

    try do
      run.(pool)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp hold_connection(pool, lock) do
    test_pid = self()

    task =
      Tasks.async_nolink(Tymeslot.TaskSupervisor, fn ->
        Repo.put_dynamic_repo(pool)

        Repo.transaction(fn ->
          lock.()
          send(test_pid, {:connection_held, self()})

          receive do
            :release_connection -> :ok
          end
        end)
      end)

    # Release a real row/pool reservation before committed fixture cleanup,
    # even when a test assertion interrupts the explicit release path.
    on_exit(fn ->
      monitor = Process.monitor(task.pid)
      Process.exit(task.pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
      after
        2_000 -> :ok
      end
    end)

    assert_receive {:connection_held, holder}, 2_000
    {task, holder}
  end

  defp release_connection({task, holder}) do
    send(holder, :release_connection)
    Task.await(task, 2_000)
  end

  defp delete_committed_user(id) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from(u in UserSchema, where: u.id == ^id))
    end)
  end

  defp delete_committed_job(id) do
    Sandbox.unboxed_run(Repo, fn ->
      # Claims deliberately outlive Oban pruning, so this real-commit fixture
      # must remove only its own claims before deleting the job it created.
      claims = from(c in DeliveryClaimSchema, where: c.oban_job_id == ^id)
      Repo.delete_all(claims)
      Repo.delete_all(from(j in Job, where: j.id == ^id))
      refute Repo.exists?(claims)
      assert Repo.get(Job, id) == nil
    end)
  end

  defp settings(owner) do
    Repo.insert!(%UserSmtpSettingsSchema{
      user_id: owner.id,
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt("smtp-login-secret"),
      password_encrypted: Encryption.encrypt("smtp-password-secret"),
      from_address: "bookings@example.com",
      from_name: "Booking brand",
      enabled: true,
      revision: 1,
      tested_revision: 1,
      tested_at: @now
    })
  end

  defp use_relay(certificates, options \\ []) do
    relay = FakeSmtpRelay.start(Keyword.put(options, :starttls, certificates))
    with_config(:tymeslot, smtp_status_test_port: relay.port)
  end

  defp email(sender) do
    Email.new()
    |> Email.from({sender.from_name, sender.from_address})
    |> Email.to("attendee@example.com")
    |> Email.subject("Booking delivery")
    |> Email.text_body("Booking details")
  end
end
