defmodule Tymeslot.Security.PrivateIPv6Test do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.PrivateIPv6

  describe "private?/1" do
    test "unspecified ::" do
      assert PrivateIPv6.private?({0, 0, 0, 0, 0, 0, 0, 0})
    end

    test "loopback ::1" do
      assert PrivateIPv6.private?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv4-mapped ::ffff:0:0/96 — boundary checks" do
      # ::ffff:10.0.0.1 — inside, embedded address is private
      assert PrivateIPv6.private?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
      # ::fffe:10.0.0.1 — one hextet short of the mapped prefix
      refute PrivateIPv6.private?({0, 0, 0, 0, 0, 0xFFFE, 0x0A00, 0x0001})
    end

    test "IPv4-compatible ::0.0.0.0/96 — boundary checks" do
      # ::10.0.0.1 — inside, embedded address is private
      assert PrivateIPv6.private?({0, 0, 0, 0, 0, 0, 0x0A00, 0x0001})
      # 0:0:0:0:0:1:10.0.0.1 — one hextet past the compatible prefix
      refute PrivateIPv6.private?({0, 0, 0, 0, 0, 1, 0x0A00, 0x0001})
    end

    test "NAT64 64:ff9b::/96 — boundary checks" do
      # 64:ff9b::10.0.0.1 — inside, embedded address is private
      assert PrivateIPv6.private?({0x0064, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001})
      # 65:ff9b::10.0.0.1 — one hextet short of the NAT64 prefix
      refute PrivateIPv6.private?({0x0065, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001})
    end

    test "IPv4-embedded addresses delegate to PrivateIPv4 for a public address" do
      refute PrivateIPv6.private?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
      refute PrivateIPv6.private?({0, 0, 0, 0, 0, 0, 0x0808, 0x0808})
      refute PrivateIPv6.private?({0x0064, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808})
    end

    test "link-local fe80::/10 — boundary checks" do
      refute PrivateIPv6.private?({0xFE7F, 0, 0, 0, 0, 0, 0, 1})
      assert PrivateIPv6.private?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert PrivateIPv6.private?({0xFEBF, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0, 1})
    end

    test "site-local fec0::/10 — boundary checks" do
      assert PrivateIPv6.private?({0xFEC0, 0, 0, 0, 0, 0, 0, 1})
      assert PrivateIPv6.private?({0xFEFF, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0, 1})
    end

    test "unique local fc00::/7 — boundary checks" do
      refute PrivateIPv6.private?({0xFBFF, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0, 1})
      assert PrivateIPv6.private?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert PrivateIPv6.private?({0xFDFF, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0, 1})
      refute PrivateIPv6.private?({0xFE00, 0, 0, 0, 0, 0, 0, 1})
    end

    test "multicast ff00::/8 — boundary checks" do
      assert PrivateIPv6.private?({0xFF00, 0, 0, 0, 0, 0, 0, 1})
      assert PrivateIPv6.private?({0xFFFF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "public addresses" do
      refute PrivateIPv6.private?({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
      refute PrivateIPv6.private?({0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111})
    end
  end

  describe "unmap/1" do
    test "decodes an IPv4-mapped address to its 4-element form" do
      assert PrivateIPv6.unmap({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}) == {10, 0, 0, 1}
    end

    test "returns any other address unchanged" do
      address = {0xFE80, 0, 0, 0, 0, 0, 0, 1}
      assert PrivateIPv6.unmap(address) == address
    end
  end
end
