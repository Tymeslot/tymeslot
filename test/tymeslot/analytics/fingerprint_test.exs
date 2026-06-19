defmodule Tymeslot.Analytics.FingerprintTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Tymeslot.Analytics.Fingerprint

  describe "hash/3" do
    test "produces a stable hash for the same inputs on the same day" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0", 42) ==
               Fingerprint.hash("1.2.3.4", "Mozilla/5.0", 42)
    end

    test "produces a different hash for a different IP" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0", 42) !=
               Fingerprint.hash("5.6.7.8", "Mozilla/5.0", 42)
    end

    test "produces a different hash for a different user agent" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0", 42) !=
               Fingerprint.hash("1.2.3.4", "curl/8.0", 42)
    end

    test "produces a different hash for a different meeting type" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0", 42) !=
               Fingerprint.hash("1.2.3.4", "Mozilla/5.0", 43)
    end

    test "returns nil when both ip and user_agent are nil" do
      assert Fingerprint.hash(nil, nil, nil) == nil
      assert Fingerprint.hash(nil, nil, 42) == nil
    end

    test "returns a hash when ip is present but user_agent is nil" do
      hash = Fingerprint.hash("1.2.3.4", nil, nil)
      assert is_binary(hash)
      assert String.length(hash) == 64
    end

    test "returns a hash when user_agent is present but ip is nil" do
      hash = Fingerprint.hash(nil, "Mozilla/5.0", nil)
      assert is_binary(hash)
      assert String.length(hash) == 64
    end

    test "produces a 64-char lowercase hex string" do
      hash = Fingerprint.hash("1.2.3.4", "Mozilla/5.0", 42)
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end
  end
end
