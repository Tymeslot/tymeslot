defmodule Tymeslot.Security.DnsResolutionTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.DnsResolution

  describe "check_private_ip/1" do
    test "rejects localhost by hostname" do
      assert {:error, _msg} = DnsResolution.check_private_ip("https://localhost/hook")
    end

    test "rejects loopback IP literal" do
      assert {:error, _msg} = DnsResolution.check_private_ip("https://127.0.0.1/hook")
    end

    test "rejects private IPv4 literals" do
      for url <- [
            "https://10.0.0.1/hook",
            "https://172.16.0.1/hook",
            "https://192.168.1.1/hook",
            "https://169.254.169.254/hook"
          ] do
        assert {:error, _msg} = DnsResolution.check_private_ip(url),
               "expected #{url} to be rejected"
      end
    end

    test "allows public IP literals" do
      assert :ok = DnsResolution.check_private_ip("https://8.8.8.8/hook")
    end

    test "returns error for URLs with no host" do
      assert {:error, _msg} = DnsResolution.check_private_ip("https:///path")
    end

    test "returns error when DNS resolution fails" do
      assert {:error, _msg} =
               DnsResolution.check_private_ip(
                 "https://this-host-definitely-does-not-exist.invalid/hook"
               )
    end
  end
end
