defmodule Tymeslot.Security.PrivateIPv4Test do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.PrivateIPv4

  describe "private?/1" do
    test "loopback 127.x.x.x" do
      assert PrivateIPv4.private?({127, 0, 0, 1})
      assert PrivateIPv4.private?({127, 255, 255, 255})
    end

    test "class A private 10.x.x.x" do
      assert PrivateIPv4.private?({10, 0, 0, 1})
      assert PrivateIPv4.private?({10, 255, 255, 255})
    end

    test "class B private 172.16.0.0/12 — boundary checks" do
      refute PrivateIPv4.private?({172, 15, 0, 0})
      assert PrivateIPv4.private?({172, 16, 0, 0})
      assert PrivateIPv4.private?({172, 31, 255, 255})
      refute PrivateIPv4.private?({172, 32, 0, 0})
    end

    test "class C private 192.168.x.x" do
      assert PrivateIPv4.private?({192, 168, 1, 1})
      assert PrivateIPv4.private?({192, 168, 0, 0})
    end

    test "link-local 169.254.x.x" do
      assert PrivateIPv4.private?({169, 254, 169, 254})
      assert PrivateIPv4.private?({169, 254, 0, 1})
    end

    test "unspecified 0.0.0.0" do
      assert PrivateIPv4.private?({0, 0, 0, 0})
    end

    test "public addresses" do
      refute PrivateIPv4.private?({8, 8, 8, 8})
      refute PrivateIPv4.private?({1, 1, 1, 1})
      refute PrivateIPv4.private?({93, 184, 216, 34})
    end
  end
end
