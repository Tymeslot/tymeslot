defmodule Tymeslot.Analytics.FingerprintTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Tymeslot.Analytics.Fingerprint

  describe "hash/3" do
    test "produces a stable hash for the same inputs on the same day" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0") ==
               Fingerprint.hash("1.2.3.4", "Mozilla/5.0")
    end

    test "produces a different hash for a different IP" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0") !=
               Fingerprint.hash("5.6.7.8", "Mozilla/5.0")
    end

    test "produces a different hash for a different user agent" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0") !=
               Fingerprint.hash("1.2.3.4", "curl/8.0")
    end

    test "ignores the session id when a network identity is present" do
      # The same visitor browsing different meeting types arrives over
      # distinct LiveView connections (distinct session ids) but must count
      # as one unique visitor — the network identity wins.
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0", "session-a") ==
               Fingerprint.hash("1.2.3.4", "Mozilla/5.0", "session-b")
    end

    test "falls back to the session id when ip and user_agent are both nil" do
      hash = Fingerprint.hash(nil, nil, "session-abc")
      assert hash =~ ~r/^[0-9a-f]{64}$/

      # Distinct anonymous connections remain distinct visitors, so the
      # unique count stays consistent with the visit count.
      assert Fingerprint.hash(nil, nil, "session-abc") !=
               Fingerprint.hash(nil, nil, "session-xyz")
    end

    test "returns nil only when there is nothing to hash" do
      assert Fingerprint.hash(nil, nil, nil) == nil
      assert Fingerprint.hash(nil, nil) == nil
    end

    test "returns a hash when ip is present but user_agent is nil" do
      hash = Fingerprint.hash("1.2.3.4", nil)
      assert is_binary(hash)
      assert String.length(hash) == 64
    end

    test "returns a hash when user_agent is present but ip is nil" do
      hash = Fingerprint.hash(nil, "Mozilla/5.0")
      assert is_binary(hash)
      assert String.length(hash) == 64
    end

    test "produces a 64-char lowercase hex string" do
      hash = Fingerprint.hash("1.2.3.4", "Mozilla/5.0")
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end
  end
end
