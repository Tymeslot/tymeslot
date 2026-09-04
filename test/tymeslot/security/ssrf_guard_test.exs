defmodule Tymeslot.Security.SsrfGuardTest do
  @moduledoc """
  Tests `Tymeslot.Security.SsrfGuard` — the request-time SSRF gate applied to
  outbound requests to user-supplied hosts (CalDAV servers, self-hosted
  MiroTalk). Enforcement is gated to `:prod`; self-hosters opt out via the
  `:allow_private_ips_for_calendar` config or an explicit `allow_private: true`.
  """

  use ExUnit.Case, async: false

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Security.SsrfGuard

  setup do
    original_env = fetch_config(:environment)
    original_resolver = fetch_config(:dns_resolver_module)
    original_allow = fetch_config(:allow_private_ips_for_calendar)

    on_exit(fn ->
      restore(:environment, original_env)
      restore(:dns_resolver_module, original_resolver)
      restore(:allow_private_ips_for_calendar, original_allow)
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

  describe "validate_pinned/2" do
    test "returns the addresses it approved so the connect can be pinned to one" do
      Application.put_env(:tymeslot, :environment, :prod)
      Application.put_env(:tymeslot, :allow_private_ips_for_calendar, false)
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardResolvingResolver)

      assert {:ok, [{93, 184, 216, 34}]} =
               SsrfGuard.validate_pinned("https://caldav.example.com/dav/")
    end

    test "returns no addresses when the request was permitted without resolving" do
      # Nothing was looked up, so there is nothing to pin to — the caller must
      # fall back to connecting by hostname rather than inventing an address.
      Application.put_env(:tymeslot, :environment, :dev)

      assert {:ok, []} = SsrfGuard.validate_pinned("https://caldav.example.com/dav/")
    end

    test "falls back to a hostname verdict when the resolver cannot return addresses" do
      # Resolvers predating `resolve_public/2` (test doubles, mostly) still get
      # to make the verdict; their requests simply go unpinned.
      Application.put_env(:tymeslot, :environment, :prod)
      Application.put_env(:tymeslot, :allow_private_ips_for_calendar, false)
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardOkResolver)

      assert {:ok, []} = SsrfGuard.validate_pinned("https://caldav.example.com/dav/")

      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardPrivateResolver)

      assert {:error, _reason} = SsrfGuard.validate_pinned("https://caldav.example.com/dav/")
    end
  end

  describe "validate/2 (non-production)" do
    setup do
      Application.put_env(:tymeslot, :environment, :test)
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardPrivateResolver)
      :ok
    end

    test "permits loopback so dev/test can target local containers" do
      assert :ok = SsrfGuard.validate("http://127.0.0.1:8800/dav.php")
    end

    test "permits a host that would resolve private, without consulting DNS" do
      assert :ok = SsrfGuard.validate("https://internal.example.com/")
    end
  end

  describe "validate/2 (production)" do
    setup do
      Application.put_env(:tymeslot, :environment, :prod)
      Application.put_env(:tymeslot, :allow_private_ips_for_calendar, false)
      :ok
    end

    test "permits a public host" do
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardOkResolver)
      assert :ok = SsrfGuard.validate("https://caldav.example.com/")
    end

    test "blocks a private IP literal before DNS resolution" do
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardOkResolver)
      assert {:error, _reason} = SsrfGuard.validate("http://10.0.0.1/dav.php")
    end

    test "blocks the cloud-metadata endpoint" do
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardOkResolver)
      assert {:error, _reason} = SsrfGuard.validate("http://169.254.169.254/latest/meta-data/")
    end

    test "blocks a host whose DNS resolves to a private address (rebinding)" do
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardPrivateResolver)
      assert {:error, _reason} = SsrfGuard.validate("https://rebind.example.com/")
    end

    test "blocks IPv6 loopback" do
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardOkResolver)
      assert {:error, _reason} = SsrfGuard.validate("http://[::1]/dav.php")
    end

    test "self-host bypass via :allow_private_ips_for_calendar config permits private hosts" do
      Application.put_env(:tymeslot, :allow_private_ips_for_calendar, true)
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardPrivateResolver)
      assert :ok = SsrfGuard.validate("http://10.0.0.1/dav.php")
    end

    test "explicit allow_private: true opt overrides the default and permits private hosts" do
      Application.put_env(:tymeslot, :dns_resolver_module, SsrfGuardPrivateResolver)
      assert :ok = SsrfGuard.validate("http://10.0.0.1/dav.php", allow_private: true)
    end
  end
end

defmodule SsrfGuardOkResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts), do: :ok
end

defmodule SsrfGuardPrivateResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end

defmodule SsrfGuardResolvingResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts), do: :ok

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def resolve_public(_url, _opts), do: {:ok, [{93, 184, 216, 34}]}
end
