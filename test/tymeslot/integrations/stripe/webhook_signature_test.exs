defmodule Tymeslot.Integrations.Stripe.WebhookSignatureTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Stripe.WebhookSignature

  @moduletag :payments
  @moduletag :webhooks
  @moduletag :unit

  @secret "whsec_test_secret"
  @body ~s({"id":"evt_1","type":"charge.succeeded"})
  @now 1_800_000_000

  defp sign(body, t, secret \\ @secret) do
    Base.encode16(:crypto.mac(:hmac, :sha256, secret, "#{t}.#{body}"), case: :lower)
  end

  defp verify(header, opts \\ []) do
    WebhookSignature.verify(@body, header, @secret, Keyword.put_new(opts, :now, @now))
  end

  test "a valid signature verifies" do
    assert verify("t=#{@now},v1=#{sign(@body, @now)}") == :ok
  end

  test "any matching v1 among several verifies" do
    assert verify("t=#{@now},v1=#{String.duplicate("a", 64)},v1=#{sign(@body, @now)}") == :ok
  end

  test "a tampered body is rejected" do
    header = "t=#{@now},v1=#{sign(~s({"id":"evt_2"}), @now)}"
    assert verify(header) == {:error, :signature_mismatch}
  end

  test "a wrong secret is rejected" do
    header = "t=#{@now},v1=#{sign(@body, @now, "whsec_other")}"
    assert verify(header) == {:error, :signature_mismatch}
  end

  test "a timestamp older than the tolerance is rejected" do
    old = @now - 301
    edge = @now - 300

    assert verify("t=#{old},v1=#{sign(@body, old)}") == {:error, :timestamp_expired}
    assert verify("t=#{edge},v1=#{sign(@body, edge)}") == :ok
  end

  test "a custom tolerance applies" do
    t = @now - 50

    assert verify("t=#{t},v1=#{sign(@body, t)}", tolerance: 10) == {:error, :timestamp_expired}
  end

  test "a future timestamp verifies" do
    future = @now + 10_000
    assert verify("t=#{future},v1=#{sign(@body, future)}") == :ok
  end

  test "only v0 signatures is :no_signatures" do
    assert verify("t=#{@now},v0=#{sign(@body, @now)}") == {:error, :no_signatures}
  end

  test "missing or malformed headers are :missing_header" do
    for header <- [nil, "", "nonsense", "t=abc,v1=x"] do
      assert verify(header) == {:error, :missing_header}
    end
  end

  test "the first t wins" do
    old = @now - 10_000
    header = "t=#{@now},t=#{old},v1=#{sign(@body, @now)}"
    assert verify(header) == :ok
  end

  test "whitespace around parts is tolerated" do
    assert verify("t=#{@now}, v1=#{sign(@body, @now)}") == :ok
  end
end
