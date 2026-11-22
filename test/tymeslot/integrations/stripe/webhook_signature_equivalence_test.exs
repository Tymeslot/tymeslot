# Temporary: compares WebhookSignature with the stripity_stripe library it replaces. Deleted with the library.
defmodule Tymeslot.Integrations.Stripe.WebhookSignatureEquivalenceTest do
  use ExUnit.Case, async: true

  alias Stripe.Webhook
  alias Tymeslot.Integrations.Stripe.WebhookSignature

  @moduletag :payments
  @moduletag :webhooks
  @moduletag :unit

  @secret "whsec_test_secret"
  @body ~s({"id":"evt_1","type":"charge.succeeded"})

  defp sign(body, t, secret \\ @secret) do
    Base.encode16(:crypto.mac(:hmac, :sha256, secret, "#{t}.#{body}"), case: :lower)
  end

  # Two deliberate differences are left out of the matrix: the library does
  # not trim whitespace around parts and ours does (covered in
  # webhook_signature_test.exs), and the library accepts a timestamp with
  # trailing characters (`t=123abc`) where ours requires a whole integer.
  test "agrees with the library across a matrix of headers" do
    now = System.system_time(:second)
    old = now - 10_000
    future = now + 10_000
    good = sign(@body, now)
    bad = String.duplicate("a", 64)

    headers = [
      "t=#{now},v1=#{good}",
      "t=#{now},v1=#{bad},v1=#{good}",
      "t=#{now},v1=#{good},v1=#{bad}",
      "t=#{now},v1=#{bad}",
      "t=#{now},v1=#{sign(@body, now, "other")}",
      "t=#{old},v1=#{sign(@body, old)}",
      "t=#{future},v1=#{sign(@body, future)}",
      "t=#{now},v0=#{good}",
      "t=#{now},v0=#{good},v1=#{good}",
      "t=#{now},t=#{old},v1=#{good}",
      "t=#{old},t=#{now},v1=#{sign(@body, old)}",
      "v1=#{good}",
      "t=#{now}",
      "t=abc,v1=x",
      "nonsense",
      "",
      nil
    ]

    for header <- headers do
      ours = WebhookSignature.verify(@body, header, @secret) == :ok

      theirs =
        match?(
          {:ok, _event},
          Webhook.construct_event(@body, header || "", @secret, 300, response_as: :raw)
        )

      assert ours == theirs,
             "disagreement for header #{inspect(header)}: ours=#{ours} theirs=#{theirs}"
    end
  end
end
