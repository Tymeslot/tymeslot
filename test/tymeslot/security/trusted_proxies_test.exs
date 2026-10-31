defmodule Tymeslot.Security.TrustedProxiesTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.TrustedProxies

  @headers_opt [headers: ~w[x-forwarded-for x-real-ip]]

  describe "contains?/2" do
    test "matches addresses inside an IPv4 or IPv6 range and nothing outside it" do
      v4 = TrustedProxies.parse!("172.64.0.0/13")
      v6 = TrustedProxies.parse!("2400:cb00::/32")

      assert TrustedProxies.contains?(v4, {172, 64, 0, 0})
      assert TrustedProxies.contains?(v4, {172, 71, 255, 255})
      refute TrustedProxies.contains?(v4, {172, 72, 0, 0})
      refute TrustedProxies.contains?(v4, {172, 63, 255, 255})

      assert TrustedProxies.contains?(v6, {0x2400, 0xCB00, 0, 0, 0, 0, 0, 1})
      refute TrustedProxies.contains?(v6, {0x2400, 0xCB01, 0, 0, 0, 0, 0, 1})
    end

    test "a bare address is a range of one, and /0 covers its whole family" do
      one = TrustedProxies.parse!("198.51.100.7")

      assert TrustedProxies.contains?(one, {198, 51, 100, 7})
      refute TrustedProxies.contains?(one, {198, 51, 100, 8})
      assert TrustedProxies.contains?(TrustedProxies.parse!("0.0.0.0/0"), {203, 0, 113, 9})
    end

    test "never matches across address families, and does not unmap" do
      # `RemoteIp` matches a forwarded `::ffff:172.68.1.1` as IPv6, so it is
      # outside an IPv4 range on the conn path and must be here too.
      v4 = TrustedProxies.parse!("172.64.0.0/13")

      refute TrustedProxies.contains?(v4, {0, 0, 0, 0, 0, 0xFFFF, 0xAC44, 0x0101})
      refute TrustedProxies.contains?(TrustedProxies.parse!("::/0"), {172, 68, 1, 1})
    end
  end

  # config/runtime.exs calls this to turn TRUSTED_PROXIES into the list the
  # conn and socket paths read. A bad entry has to stop the boot: `RemoteIp`
  # parses `proxies:` on every request and would otherwise raise there.
  describe "from_env/1" do
    test "unset or blank yields no ranges" do
      assert TrustedProxies.from_env(nil) == []
      assert TrustedProxies.from_env("") == []
      assert TrustedProxies.from_env(" , ,") == []
    end

    test "accepts IPv4 and IPv6 ranges and bare addresses, trimming whitespace" do
      assert TrustedProxies.from_env(" 173.245.48.0/20, 2400:cb00::/32 ,198.51.100.7,") ==
               ["173.245.48.0/20", "2400:cb00::/32", "198.51.100.7"]
    end

    test "accepts the whole-family and single-address prefixes" do
      assert TrustedProxies.from_env("0.0.0.0/0,198.51.100.7/32,::/0,2001:db8::1/128") ==
               ["0.0.0.0/0", "198.51.100.7/32", "::/0", "2001:db8::1/128"]
    end

    test "everything it accepts, RemoteIp accepts too" do
      proxies =
        TrustedProxies.from_env("173.245.48.0/20,2400:cb00::/32,198.51.100.7")

      headers = [{"x-forwarded-for", "203.0.113.9, 173.245.48.1"}]

      assert RemoteIp.from(headers, @headers_opt ++ [proxies: proxies]) == {203, 0, 113, 9}
    end

    test "raises on an entry that is not an address or range, naming it" do
      for entry <- [
            "not-an-ip",
            "10.0.0/8",
            "10.0.0.0/",
            "10.0.0.0/abc",
            "10.0.0.0/8/9",
            "10.0.0.0/33",
            "10.0.0.0/-1",
            "2400:cb00::/129",
            "198.51.100.7:443"
          ] do
        assert_raise ArgumentError,
                     ~r/TRUSTED_PROXIES entry #{Regex.escape(inspect(entry))}/,
                     fn ->
                       TrustedProxies.from_env("173.245.48.0/20, #{entry}")
                     end
      end
    end
  end
end
