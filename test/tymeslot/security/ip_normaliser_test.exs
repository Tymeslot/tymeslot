defmodule Tymeslot.Security.IPNormaliserTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.IPNormaliser

  describe "normalize_for_storage/1" do
    test "returns nil for nil input" do
      assert nil == IPNormaliser.normalize_for_storage(nil)
    end

    test "returns nil for false" do
      assert nil == IPNormaliser.normalize_for_storage(false)
    end

    test "returns trimmed string for a binary IP" do
      assert "192.168.1.1" == IPNormaliser.normalize_for_storage("192.168.1.1")
    end

    test "trims surrounding whitespace from binary IP strings" do
      assert "10.0.0.1" == IPNormaliser.normalize_for_storage("  10.0.0.1  ")
    end

    test "converts a printable charlist (e.g. from :inet.ntoa) to a string" do
      charlist = ~c"127.0.0.1"
      assert "127.0.0.1" == IPNormaliser.normalize_for_storage(charlist)
    end

    test "returns nil for a non-printable charlist" do
      non_printable = [0, 1, 2, 255]
      assert nil == IPNormaliser.normalize_for_storage(non_printable)
    end

    test "converts an IPv4 tuple to its dotted-decimal string representation" do
      assert "203.0.113.5" == IPNormaliser.normalize_for_storage({203, 0, 113, 5})
    end

    test "converts an IPv6 tuple to its canonical string representation" do
      # 2001:db8::1
      ipv6 = {8193, 3512, 0, 0, 0, 0, 0, 1}
      result = IPNormaliser.normalize_for_storage(ipv6)
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "returns nil for unrecognised types" do
      assert nil == IPNormaliser.normalize_for_storage(42)
      assert nil == IPNormaliser.normalize_for_storage(%{ip: "1.2.3.4"})
      assert nil == IPNormaliser.normalize_for_storage(:some_atom)
    end
  end

  describe "maybe_set_signup_ip/3" do
    test "adds signup_ip to changes when existing value is nil" do
      result = IPNormaliser.maybe_set_signup_ip(%{}, nil, "1.2.3.4")
      assert result == %{signup_ip: "1.2.3.4"}
    end

    test "adds signup_ip to changes when existing value is an empty string" do
      result = IPNormaliser.maybe_set_signup_ip(%{}, "", "1.2.3.4")
      assert result == %{signup_ip: "1.2.3.4"}
    end

    test "adds signup_ip to changes when existing value is \"unknown\"" do
      result = IPNormaliser.maybe_set_signup_ip(%{}, "unknown", "1.2.3.4")
      assert result == %{signup_ip: "1.2.3.4"}
    end

    test "preserves existing signup_ip and returns changes unchanged when already set" do
      existing_changes = %{name: "Alice"}
      result = IPNormaliser.maybe_set_signup_ip(existing_changes, "9.9.9.9", "1.2.3.4")
      assert result == existing_changes
      refute Map.has_key?(result, :signup_ip)
    end

    test "merges signup_ip into an existing changes map without clobbering other keys" do
      changes = %{name: "Bob", role: "admin"}
      result = IPNormaliser.maybe_set_signup_ip(changes, nil, "5.5.5.5")
      assert result.signup_ip == "5.5.5.5"
      assert result.name == "Bob"
      assert result.role == "admin"
    end
  end
end
