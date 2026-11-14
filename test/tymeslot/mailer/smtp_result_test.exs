defmodule Tymeslot.Mailer.SMTPResultTest do
  @moduledoc """
  Verifies SMTP classification preserves retry decisions without provider text.
  """

  use ExUnit.Case, async: true

  @moduletag :emails

  alias Tymeslot.Mailer.SMTPResult

  test "enhanced destination statuses are permanent recipient failures" do
    for status <- ["5.1.1", "5.1.2", "5.1.3", "5.1.10", "5.2.1"] do
      reason = {:send, {:permanent_failure, ~c"relay", "550 #{status} rejected secret"}}

      assert SMTPResult.permanent_rejection?(reason)
      assert SMTPResult.classify(reason) == :recipient_rejected
    end
  end

  test "sender, relay and temporary failures remain retryable" do
    reasons = [
      {:send, {:permanent_failure, ~c"relay", "553 5.7.1 Sender not permitted secret"}},
      {:send, {:permanent_failure, ~c"relay", "550 Rejected secret"}},
      {:send, {:permanent_failure, ~c"relay", "550 5.1.11 Unrecognized status secret"}},
      {:send, {:temporary_failure, ~c"relay", "450 5.1.1 Temporary secret"}},
      {:retries_exceeded, {:permanent_failure, ~c"relay", "550 5.1.1 secret"}}
    ]

    for reason <- reasons do
      refute SMTPResult.permanent_rejection?(reason)
      assert SMTPResult.classify(reason) == :delivery_failed
    end
  end

  test "authentication and TLS requirements have safe operational categories" do
    assert SMTPResult.classify({:retries_exceeded, {:missing_requirement, ~c"relay", :auth}}) ==
             :authentication_failed

    assert SMTPResult.classify({:no_more_hosts, {:permanent_failure, ~c"relay", :auth_failed}}) ==
             :authentication_failed

    assert SMTPResult.classify({:retries_exceeded, {:missing_requirement, ~c"relay", :tls}}) ==
             :tls_required
  end

  test "session opening timeouts remain distinct from possibly sent transactions" do
    assert SMTPResult.classify(
             {:retries_exceeded, {:network_failure, ~c"relay", {:error, :timeout}}}
           ) == :session_timeout

    assert SMTPResult.classify({:send, {:network_failure, ~c"relay", {:error, :timeout}}}) ==
             :ambiguous_timeout

    assert SMTPResult.classify(:timeout) == :ambiguous_timeout

    assert SMTPResult.classify({:send, {:network_failure, ~c"relay", {:error, :closed}}}) ==
             :delivery_failed
  end

  test "unknown responses cannot expose relay replies or credentials" do
    assert SMTPResult.classify({:unexpected, "smtp-user", "smtp-password"}) == :delivery_failed
  end
end
