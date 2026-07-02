defmodule Tymeslot.Webhooks.SsrfValidatorTest do
  @moduledoc """
  Tests `Tymeslot.Webhooks.SsrfValidator` — the SSRF protection gate that
  every webhook URL is checked against before delivery and on every redirect
  hop.
  """

  use ExUnit.Case, async: false

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Webhooks.SsrfValidator

  setup do
    original_env = fetch_config(:environment)
    original_resolver = fetch_config(:dns_resolver_module)
    original_allow = fetch_config(:allow_private_ips_for_webhooks)

    on_exit(fn ->
      restore(:environment, original_env)
      restore(:dns_resolver_module, original_resolver)
      restore(:allow_private_ips_for_webhooks, original_allow)
    end)

    :ok
  end

  defp fetch_config(key) do
    case Application.fetch_env(:tymeslot, key) do
      {:ok, value} -> {:set, value}
      :error -> :unset
    end
  end

  defp restore(key, :unset), do: Application.delete_env(:tymeslot, key)
  defp restore(key, {:set, value}), do: Application.put_env(:tymeslot, key, value)

  describe "check/1 (non-production)" do
    test "accepts a regular https URL" do
      Application.put_env(:tymeslot, :environment, :test)
      assert :ok = SsrfValidator.check("https://example.com/hook")
    end

    test "accepts an http loopback URL (so dev/test can target localhost)" do
      Application.put_env(:tymeslot, :environment, :test)
      assert :ok = SsrfValidator.check("http://127.0.0.1:4000/hook")
    end

    test "rejects an unparseable URL" do
      Application.put_env(:tymeslot, :environment, :test)
      assert {:error, _reason} = SsrfValidator.check("not a url at all")
    end
  end

  describe "check/1 (production)" do
    setup do
      Application.put_env(:tymeslot, :environment, :prod)
      :ok
    end

    test "rejects http URLs (https is enforced)" do
      Application.put_env(:tymeslot, :dns_resolver_module, AlwaysOkResolver)
      assert {:error, _reason} = SsrfValidator.check("http://example.com/hook")
    end

    test "rejects URLs with private IP literals before DNS resolution" do
      Application.put_env(:tymeslot, :dns_resolver_module, AlwaysOkResolver)
      assert {:error, _reason} = SsrfValidator.check("https://10.0.0.1/hook")
    end

    test "rejects URLs whose DNS resolves to a private IP" do
      Application.put_env(:tymeslot, :dns_resolver_module, PrivateIpResolver)
      assert {:error, _reason} = SsrfValidator.check("https://example.com/hook")
    end

    test "accepts URLs whose DNS resolves to a public IP" do
      Application.put_env(:tymeslot, :dns_resolver_module, AlwaysOkResolver)
      assert :ok = SsrfValidator.check("https://example.com/hook")
    end

    test "rejects IPv6 loopback (::1)" do
      Application.put_env(:tymeslot, :dns_resolver_module, AlwaysOkResolver)
      assert {:error, _reason} = SsrfValidator.check("https://[::1]/hook")
    end

    test "rejects IPv6 unique-local (fc00::/7)" do
      Application.put_env(:tymeslot, :dns_resolver_module, AlwaysOkResolver)
      assert {:error, _reason} = SsrfValidator.check("https://[fc00::1]/hook")
    end

    test "rejects IPv6 link-local (fe80::/10)" do
      Application.put_env(:tymeslot, :dns_resolver_module, AlwaysOkResolver)
      assert {:error, _reason} = SsrfValidator.check("https://[fe80::1]/hook")
    end
  end

  describe "check/1 (self-host opt-out via :allow_private_ips_for_webhooks)" do
    setup do
      Application.put_env(:tymeslot, :environment, :prod)
      Application.put_env(:tymeslot, :allow_private_ips_for_webhooks, true)
      # A resolver that would reject everything — proving the opt-out skips DNS.
      Application.put_env(:tymeslot, :dns_resolver_module, PrivateIpResolver)
      :ok
    end

    test "permits a private IP literal" do
      assert :ok = SsrfValidator.check("https://10.0.0.1/hook")
    end

    test "permits a host whose DNS resolves to a private IP (DNS check skipped)" do
      assert :ok = SsrfValidator.check("https://internal.example.org/hook")
    end

    test "permits http (HTTPS no longer enforced)" do
      assert :ok = SsrfValidator.check("http://internal.example.org/hook")
    end

    test "still rejects a syntactically invalid URL" do
      assert {:error, _reason} = SsrfValidator.check("not a url at all")
    end
  end
end

defmodule AlwaysOkResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts), do: :ok
end

defmodule PrivateIpResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end
