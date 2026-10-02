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
      assert IPNormaliser.normalize_for_storage(ipv6) == "2001:db8::1"
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

  describe "truncate_for_log/1" do
    test "keeps an IPv4 address's /24" do
      assert {:ok, "203.0.113.0/24"} == IPNormaliser.truncate_for_log("203.0.113.77")
    end

    test "keeps an IPv6 address's /48" do
      assert {:ok, "2001:db8:85a3::/48"} ==
               IPNormaliser.truncate_for_log("2001:db8:85a3:8d3:1319:8a2e:370:7348")
    end

    test "truncates an IPv4-mapped IPv6 address as the IPv4 address it carries" do
      assert {:ok, "203.0.113.0/24"} == IPNormaliser.truncate_for_log("::ffff:203.0.113.77")
    end

    test "accepts :inet tuples and printable charlists" do
      assert {:ok, "203.0.113.0/24"} == IPNormaliser.truncate_for_log({203, 0, 113, 77})

      assert {:ok, "2001:db8:1::/48"} ==
               IPNormaliser.truncate_for_log({0x2001, 0xDB8, 1, 2, 0, 0, 0, 9})

      assert {:ok, "203.0.113.0/24"} == IPNormaliser.truncate_for_log(~c"203.0.113.77")
    end

    test "truncates every entry of a forwarded-for list" do
      assert {:ok, "203.0.113.0/24, 10.0.0.0/24"} ==
               IPNormaliser.truncate_for_log("203.0.113.77, 10.0.0.1")
    end

    test "refuses anything that is not an address" do
      for value <- ["unknown", "203.0.113.77:443", "203.0.113.77, junk", "", nil, 42, {1, 2}] do
        assert :error == IPNormaliser.truncate_for_log(value),
               "expected #{inspect(value)} refused"
      end
    end
  end
end
