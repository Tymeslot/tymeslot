defmodule Tymeslot.EmailSending.TransportTest do
  @moduledoc """
  Drives the user SMTP transport through real TLS and SMTP authentication.

  Only the destination and trust store are fixtures: production hostname,
  port/security validation, AUTH policy, encoding and task bounds all run.
  A deliberately unresolvable hostname proves connection uses the resolved
  endpoint; its certificate must still match that original hostname.
  """
  use ExUnit.Case, async: false

  @moduletag :emails
  @moduletag :security
  @moduletag :integration

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  alias Swoosh.Email
  alias Tymeslot.EmailSending.{Destination, Transport}
  alias Tymeslot.Test.FakeSmtpRelay

  @hostname "smtp.unresolvable.invalid"

  defmodule TestDestination do
    @moduledoc false
    @behaviour Destination

    @impl Destination
    def resolve(_host, _port) do
      {:ok,
       %{
         address: {127, 0, 0, 1},
         port: Application.fetch_env!(:tymeslot, :smtp_transport_test_port)
       }}
    end
  end

  setup_all do
    %{
      certificates: FakeSmtpRelay.certificates(~c"smtp.unresolvable.invalid"),
      mismatched: FakeSmtpRelay.certificates(~c"wrong.invalid")
    }
  end

  setup do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      user_smtp_destination_module: TestDestination
    )

    :ok
  end

  test "feature disabled refuses before opening a connection" do
    with_config(:tymeslot, user_smtp_enabled: false)
    assert {:error, :feature_disabled} = Transport.deliver(email(), candidate())
  end

  test "pins the connection but verifies the original hostname over implicit TLS", %{
    certificates: certificates
  } do
    relay = FakeSmtpRelay.start(implicit_tls: certificates)
    use_relay(relay, certificates)

    assert {:ok, :accepted} = Transport.deliver(email(), candidate())
    assert_receive {:smtp_relay, {:tls_up, _info}}
    assert_receive {:smtp_relay, {:auth, _mechanism}}
    assert_receive {:smtp_relay, {:message, body}}
    assert body =~ "Subject: SMTP test"
  end

  test "requires STARTTLS before authentication", %{certificates: certificates} do
    relay = FakeSmtpRelay.start(starttls: certificates)
    use_relay(relay, certificates)

    assert {:ok, :accepted} = Transport.deliver(email(), candidate(587, :starttls))
    assert_receive {:smtp_relay, {:tls_up, _info}}
    assert_receive {:smtp_relay, {:auth, _mechanism}}
    assert_receive {:smtp_relay, {:message, _body}}
  end

  test "refuses a trusted certificate with the wrong hostname", %{mismatched: certificates} do
    relay = FakeSmtpRelay.start(implicit_tls: certificates)
    use_relay(relay, certificates)

    assert {:error, :delivery_failed} = Transport.deliver(email(), candidate())
    refute_received {:smtp_relay, {:auth, _mechanism}}
    refute_received {:smtp_relay, {:message, _body}}
  end

  test "refuses unavailable AUTH instead of reopening without credentials", %{
    certificates: certificates
  } do
    relay = FakeSmtpRelay.start(implicit_tls: certificates, auth: :not_offered)
    use_relay(relay, certificates)

    assert {:error, :authentication_failed} = Transport.deliver(email(), candidate())
    refute_received {:smtp_relay, {:mail_from, _line}}
    refute_received {:smtp_relay, {:message, _body}}
  end

  test "reports a rejected password without exposing credentials", %{certificates: certificates} do
    relay = FakeSmtpRelay.start(implicit_tls: certificates, auth: :reject)
    use_relay(relay, certificates)

    log =
      capture_log(fn ->
        assert {:error, :authentication_failed} = Transport.deliver(email(), candidate())
      end)

    refute log =~ "smtp-secret-user"
    refute log =~ "smtp-secret-password"
    refute_received {:smtp_relay, {:mail_from, _line}}
  end

  test "refuses a relay without STARTTLS before sending credentials", %{
    certificates: certificates
  } do
    relay = FakeSmtpRelay.start()
    use_relay(relay, certificates)

    assert {:error, :tls_required} = Transport.deliver(email(), candidate(587, :starttls))
    refute_received {:smtp_relay, {:auth, _mechanism}}
    refute_received {:smtp_relay, {:message, _body}}
  end

  test "bounds a silent relay and closes its task", %{certificates: certificates} do
    relay = FakeSmtpRelay.start(greet: false)
    use_relay(relay, certificates)
    with_config(:tymeslot, email_send_deadline_ms: 100)

    assert {:error, :timeout} = Transport.deliver(email(), candidate(587, :starttls))
  end

  test "validates credentials, From headers and security modes at its own boundary" do
    for changes <- [
          %{password: ""},
          %{password: "secret\r\n"},
          %{username: nil},
          %{port: 25},
          %{security: :never}
        ] do
      assert {:error, :invalid_settings} =
               Transport.deliver(email(), Map.merge(candidate(), changes))
    end

    injected = %{email() | from: {"Sender\r\nInjected", "sender@example.com"}}
    assert {:error, :invalid_settings} = Transport.deliver(injected, candidate())
  end

  defp use_relay(relay, certificates) do
    with_config(:tymeslot,
      smtp_transport_test_port: relay.port,
      user_smtp_cacertfile: certificates.cacertfile
    )
  end

  defp candidate(port \\ 465, security \\ :implicit_tls) do
    %{
      host: @hostname,
      port: port,
      security: security,
      username: "smtp-secret-user",
      password: "smtp-secret-password"
    }
  end

  defp email do
    Email.new()
    |> Email.from({"Sender", "sender@example.com"})
    |> Email.to("recipient@example.com")
    |> Email.subject("SMTP test")
    |> Email.text_body("Test message")
  end
end
