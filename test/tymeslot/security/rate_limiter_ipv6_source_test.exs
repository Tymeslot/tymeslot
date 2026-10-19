defmodule Tymeslot.Security.RateLimiterIPv6SourceTest do
  @moduledoc """
  Every per-IP bucket counts an IPv6 client by its /64.

  An IPv6 host is usually handed a whole /64 and can pick a fresh address
  from it for every request. A bucket keyed on the full address therefore
  gives that host an unlimited supply of fresh budgets, so these tests rotate
  through addresses in one /64 and expect the bucket to refuse once its
  budget is spent, while a neighbouring /64 keeps its own.

  Each `:source`-scoped limit runs the same test through `parameterize`, so a
  bucket that goes back to keying on the raw address fails under its own name.
  """

  use ExUnit.Case,
    async: false,
    parameterize:
      for(
        {name, limit} <- [
          signup_ip: 5,
          password_reset_ip: 5,
          password_reset_submit: 30,
          verification_ip: 5,
          verification_link: 30,
          email_change_verify: 30,
          oauth_initiation: 10,
          oauth_callback: 20,
          oauth_completion: 6,
          booking_submit: 10,
          meeting_cancel: 10,
          meeting_approval: 20,
          meeting_keep: 10,
          guest_rsvp: 60,
          seat_manage: 60,
          webhook: 100,
          stripe_webhook: 1_000,
          calendar_push: 1_000,
          freebusy: 60,
          meeting_ics: 60,
          healthcheck: 30,
          poll_register: 5,
          poll_vote: 10,
          analytics_ip: 300
        ],
        do: %{name: name, limit: limit}
      )

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    on_exit(fn -> RateLimiter.clear_all() end)
    :ok
  end

  test "addresses in one IPv6 /64 share a bucket", %{name: name, limit: limit} do
    within_budget = for i <- 1..limit, do: charge(name, address_in("2001:db8:a:b", i))
    assert Enum.reject(within_budget, &(&1 == :allow)) == []

    assert charge(name, address_in("2001:db8:a:b", limit + 1)) == :deny
    assert charge(name, address_in("2001:db8:a:c", 1)) == :allow
  end

  test "an IPv4-mapped address shares the bucket of the IPv4 address it carries",
       %{name: name, limit: limit} do
    within_budget = for _i <- 1..limit, do: charge(name, "198.51.100.7")
    assert Enum.reject(within_budget, &(&1 == :allow)) == []

    assert charge(name, "::ffff:198.51.100.7") == :deny
    assert charge(name, "198.51.100.8") == :allow
  end

  # A distinct host part per call, so every charge comes from a new address.
  defp address_in(prefix, i), do: "#{prefix}:#{Integer.to_string(i, 16)}::1"

  defp charge(limit, ip), do: limit |> RateLimiter.check(ip) |> outcome()

  defp outcome(:ok), do: :allow
  defp outcome({:error, :rate_limited, _message}), do: :deny
end
