defmodule Tymeslot.Emails.UserSmtpDeliveryTest do
  @moduledoc """
  Drives resolved booking senders through real SMTP and independent breakers.

  The fixture changes only DNS endpoint and CA trust. Authentication, TLS,
  encoded messages, deadlines, error classification and delivery policy run
  through the production transport boundary.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :integration
  @moduletag :security

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  alias Swoosh.Email
  alias Tymeslot.Clock
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.{Breakers, Connections, Sender, UserSmtpSettingsSchema}
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.FakeSmtpRelay

  defmodule Destination do
    @moduledoc false
    @behaviour Tymeslot.EmailSending.Destination

    @impl Tymeslot.EmailSending.Destination
    def resolve(_host, _port) do
      {:ok,
       %{
         address: {127, 0, 0, 1},
         port: Application.fetch_env!(:tymeslot, :user_delivery_test_port)
       }}
    end
  end

  defmodule RaisingDestination do
    @moduledoc false
    @behaviour Tymeslot.EmailSending.Destination

    @impl Tymeslot.EmailSending.Destination
    def resolve(_host, _port), do: raise("smtp-password-secret")
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

    owner = insert(:user, verified_at: Clock.utc_now())
    %{owner: owner, sender: sender(owner)}
  end

  test "custom delivery authenticates and consumes the selected identity", context do
    use_relay(context.certificates)

    assert {:ok, :accepted} = Delivery.deliver(email(context.sender), sender: context.sender)
    assert_receive {:smtp_relay, {:auth, _mechanism}}
    assert_receive {:smtp_relay, {:message, body}}
    assert body =~ "bookings@example.com"
    refute_received {_reference, :smtp_session_opened}

    status = CircuitBreaker.status(Breakers.name(context.sender))
    assert status.status == :closed
    assert status.config == Delivery.email_breaker_config()
  end

  test "one account's failures never open another account or platform breaker", context do
    first = context.sender
    second = sender(insert(:user, verified_at: Clock.utc_now()))
    use_relay(context.certificates, auth: :reject)

    for _attempt <- 1..3 do
      assert {:error, :authentication_failed} = Delivery.deliver(email(first), sender: first)
    end

    assert CircuitBreaker.status(Breakers.name(first)).status == :open
    use_relay(context.certificates)

    assert {:ok, :accepted} = Delivery.deliver(email(second), sender: second)
    assert {:error, :circuit_open} = Delivery.deliver(email(first), sender: first)
    assert {:ok, _receipt} = Delivery.deliver(email(Sender.platform()))
    assert CircuitBreaker.status(Breakers.name(second)).status == :closed
  end

  test "permanent recipient rejection is safe and does not trip the account breaker", context do
    use_relay(context.certificates, rcpt_reply: "550 5.1.1 No such mailbox smtp-password-secret")

    log =
      capture_log(fn ->
        assert {:error, {:recipient_rejected, rejection}} =
                 Delivery.deliver(email(context.sender), sender: context.sender)

        assert rejection.reason == :recipient_rejected
        refute inspect(rejection) =~ "smtp-password-secret"
      end)

    refute log =~ "smtp-password-secret"
    refute_received {_reference, :smtp_session_opened}
    assert CircuitBreaker.status(Breakers.name(context.sender)).failure_count == 0
  end

  test "a generic sender or relaying rejection remains a retryable configuration failure",
       context do
    use_relay(context.certificates, rcpt_reply: "553 5.7.1 Sender not authorized")

    assert {:error, :delivery_failed} =
             Delivery.deliver(email(context.sender), sender: context.sender)

    refute_received {_reference, :smtp_session_opened}
    assert CircuitBreaker.status(Breakers.name(context.sender)).failure_count == 1
  end

  test "custom transport exceptions cannot escape through results or task logs", context do
    with_config(:tymeslot, user_smtp_destination_module: RaisingDestination)

    log =
      capture_log(fn ->
        assert {:error, :delivery_failed} =
                 Delivery.deliver(email(context.sender), sender: context.sender)
      end)

    assert log =~ "User SMTP transport failed unexpectedly"
    refute log =~ "smtp-password-secret"
    refute_received {_reference, :smtp_session_opened}
    assert CircuitBreaker.status(Breakers.name(context.sender)).failure_count == 1
  end

  test "booking and configuration tests share the owner cap without blocking other owners",
       context do
    use_relay(context.certificates, after_data: :silent)
    with_config(:tymeslot, email_send_deadline_ms: 3_000)
    hold_connection_slots(context.sender.owner_id, Connections.limit() - 1)

    pending =
      Tasks.async_nolink(Tymeslot.TaskSupervisor, fn ->
        Delivery.deliver(email(context.sender), sender: context.sender)
      end)

    assert_receive {:smtp_relay, {:message, _body}}, 1_000
    flush_relay_events()

    assert {:error, :rate_limited} =
             Delivery.deliver(email(context.sender), sender: context.sender)

    assert {:error, :rate_limited} =
             EmailSending.test_and_save_settings(
               context.owner,
               %{},
               {context.sender.settings_id, context.sender.revision}
             )

    refute_received {:smtp_relay, _event}
    assert CircuitBreaker.status(Breakers.name(context.sender)).failure_count == 0

    other = sender(insert(:user, verified_at: Clock.utc_now()))
    use_relay(context.certificates)
    assert {:ok, :accepted} = Delivery.deliver(email(other), sender: other)
    assert {:ok, :assumed_delivered} = Task.await(pending, 4_000)
  end

  test "a killed delivery caller terminates its socket task and frees the owner cap", context do
    use_relay(context.certificates, after_data: :silent)
    hold_connection_slots(context.sender.owner_id, Connections.limit() - 1)

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        Delivery.deliver(email(context.sender), sender: context.sender)
      end)

    assert_receive {:smtp_relay, {:message, _body}}, 1_000

    assert {:links, [transport]} = Process.info(caller, :links)
    transport_monitor = Process.monitor(transport)

    # Monitoring is asynchronous. This request acknowledges its installation
    # before a linked exit from the caller can race it and report :noproc.
    assert {:monitored_by, monitors} = Process.info(transport, :monitored_by)
    assert self() in monitors

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    assert_receive {:DOWN, ^transport_monitor, :process, ^transport, :killed}

    use_relay(context.certificates)
    assert {:ok, :accepted} = Delivery.deliver(email(context.sender), sender: context.sender)
  end

  test "a timeout before SMTP session opening is retryable and never assumed delivered",
       context do
    relay = FakeSmtpRelay.start(greet: false)
    with_config(:tymeslot, user_delivery_test_port: relay.port, email_send_deadline_ms: 100)

    assert {{:error, :session_timeout}, false} =
             Delivery.with_ambiguous_timeouts(:retry_once, fn ->
               Delivery.deliver(email(context.sender), sender: context.sender)
             end)

    refute_received {_reference, :smtp_session_opened}
  end

  test "a timeout after DATA follows the existing bounded ambiguity policy", context do
    use_relay(context.certificates, after_data: :silent)
    with_config(:tymeslot, email_send_deadline_ms: 1_000)

    assert {{:error, {:ambiguous, :ambiguous_timeout}}, true} =
             Delivery.with_ambiguous_timeouts(
               :retry_once,
               fn -> Delivery.deliver(email(context.sender), sender: context.sender) end,
               on_ambiguous: fn -> send(self(), :ambiguous_recorded) end
             )

    assert_received :ambiguous_recorded
    assert_receive {:smtp_relay, {:message, _body}}
    refute_received {_reference, :smtp_session_opened}

    assert {{:ok, :assumed_delivered}, false} =
             Delivery.with_ambiguous_timeouts(:assume_delivered, fn ->
               Delivery.deliver(email(context.sender), sender: context.sender)
             end)
  end

  test "changed or disabled settings fail without silently choosing the platform", context do
    use_relay(context.certificates)
    sender = context.sender

    Repo.update_all(from(s in UserSmtpSettingsSchema, where: s.id == ^sender.settings_id),
      set: [enabled: false, revision: 2]
    )

    assert {:error, :settings_changed} = Delivery.deliver(email(sender), sender: sender)
    refute_received {:smtp_relay, :ehlo}
  end

  test "custom delivery cannot substitute a From identity after resolution", context do
    use_relay(context.certificates)

    forged = Email.from(email(context.sender), {"Other sender", "other@example.com"})
    assert {:error, :invalid_sender} = Delivery.deliver(forged, sender: context.sender)
    refute_received {:smtp_relay, :ehlo}
  end

  test "valid display-name whitespace survives header cleanup and sender validation", context do
    use_relay(context.certificates)
    sender = %{context.sender | from_name: "Customer  booking sender"}

    Repo.update_all(from(s in UserSmtpSettingsSchema, where: s.id == ^sender.settings_id),
      set: [from_name: sender.from_name]
    )

    assert {:ok, :accepted} = Delivery.deliver(email(sender), sender: sender)
    assert_receive {:smtp_relay, {:message, body}}
    assert body =~ "Customer booking sender"
  end

  test "a new configuration revision gets its own breaker", context do
    sender = context.sender
    use_relay(context.certificates, auth: :reject)

    for _attempt <- 1..3 do
      assert {:error, :authentication_failed} = Delivery.deliver(email(sender), sender: sender)
    end

    Repo.update_all(from(s in UserSmtpSettingsSchema, where: s.id == ^sender.settings_id),
      set: [revision: 2, tested_revision: 2]
    )

    replacement = %{sender | revision: 2}
    use_relay(context.certificates)
    assert {:ok, :accepted} = Delivery.deliver(email(replacement), sender: replacement)
    assert Breakers.name(sender) != Breakers.name(replacement)
    assert CircuitBreaker.status(Breakers.name(sender)).status == :open
  end

  defp sender(user) do
    %UserSmtpSettingsSchema{
      user_id: user.id,
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt("smtp-user-#{user.id}"),
      password_encrypted: Encryption.encrypt("smtp-password-secret"),
      from_address: "bookings@example.com",
      from_name: "Custom booking sender",
      enabled: true,
      revision: 1,
      tested_revision: 1,
      tested_at: Clock.utc_now()
    }
    |> Repo.insert!()
    |> Sender.from_settings()
  end

  defp email(sender) do
    Email.new()
    |> Email.from({sender.from_name, sender.from_address})
    |> Email.to("attendee@example.net")
    |> Email.subject("Booking delivery")
    |> Email.text_body("Your booking details.")
  end

  defp use_relay(certificates, options \\ []) do
    relay = FakeSmtpRelay.start(Keyword.put(options, :starttls, certificates))
    with_config(:tymeslot, user_delivery_test_port: relay.port)
  end

  defp flush_relay_events do
    receive do
      {:smtp_relay, _event} -> flush_relay_events()
    after
      0 -> :ok
    end
  end

  defp hold_connection_slots(owner_id, count) do
    parent = self()

    for _slot <- 1..count do
      holder =
        spawn(fn ->
          Connections.with_owner(owner_id, fn ->
            send(parent, {:reserved, self()})

            receive do
              :release -> :ok
            end
          end)
        end)

      on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
      assert_receive {:reserved, ^holder}
    end
  end
end
