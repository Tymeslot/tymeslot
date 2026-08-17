defmodule Tymeslot.Security.RateLimiterProxyPeerIsolationTest do
  @moduledoc """
  Every IP-keyed rate limit on the LiveView path depends on one property:
  `ClientIP.get_from_mount/1` must resolve two visitors behind the same reverse
  proxy to two different addresses. When it does not, the buckets keyed on that
  address stop being per-visitor and become a single allowance shared by the
  whole deployment, so ordinary traffic locks ordinary users out.

  That is not hypothetical. Production served every socket-path visitor as
  `::ffff:172.18.0.1`, the proxy's own IPv4-mapped address, because the mapped
  form matched none of the trusted-peer clauses and the forwarded headers were
  discarded as untrusted. Three unrelated signups then spent the five-per-hour
  verification allowance a fourth user needed, and that fourth signup failed.

  These tests assert the consequence rather than the mechanism, so they still
  fail if the collapse returns by some other route: a change to the endpoint's
  `connect_info`, to the trusted-peer ranges, or to how buckets are keyed.
  """

  use ExUnit.Case, async: false

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  # What a dual-stack listener reports for an IPv4 reverse proxy on the Docker
  # bridge: ::ffff:172.18.0.1, as an 8-element IPv4-mapped tuple.
  @proxy_peer %{address: {0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 0x0001}, port: 0, ssl_cert: nil}

  # @verification_limits' tightest window allows 5 per hour per IP.
  @verification_hourly_limit 5

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp socket_forwarded_from(client_ip) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      transport_pid: self(),
      private: %{
        connect_info: %{
          peer_data: @proxy_peer,
          x_headers: [{"x-forwarded-for", client_ip}]
        },
        connect_params: %{}
      }
    }
  end

  test "two visitors behind one reverse proxy resolve to their own addresses" do
    assert ClientIP.get_from_mount(socket_forwarded_from("203.0.113.10")) == "203.0.113.10"
    assert ClientIP.get_from_mount(socket_forwarded_from("198.51.100.20")) == "198.51.100.20"
  end

  test "one visitor exhausting the verification allowance does not block another" do
    first = ClientIP.get_from_mount(socket_forwarded_from("203.0.113.10"))
    second = ClientIP.get_from_mount(socket_forwarded_from("198.51.100.20"))

    # Distinct user ids, so it is the per-IP bucket that fills rather than the
    # per-user one — the production sequence, where the users who spent the
    # allowance were not the user who was then refused.
    for n <- 1..@verification_hourly_limit do
      assert :ok = RateLimiter.check_verification_rate_limit("spender-#{n}", first)
    end

    assert {:error, :rate_limited, _message} =
             RateLimiter.check_verification_rate_limit("spender-next", first)

    assert :ok = RateLimiter.check_verification_rate_limit("bystander", second)
  end

  test "the shared proxy address is never itself the rate-limit key" do
    resolved = ClientIP.get_from_mount(socket_forwarded_from("203.0.113.10"))

    refute resolved == "::ffff:172.18.0.1"
    refute resolved == "172.18.0.1"
  end
end
