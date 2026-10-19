defmodule Tymeslot.Security.RateLimiterKeysTest do
  @moduledoc """
  Pins every rate-limit bucket key, byte for byte.

  Live counters are keyed on these strings, so a key that changes shape resets
  every counter under it on deploy and, worse, can silently split one budget in
  two. Each expectation is a literal: nothing here is derived from the table it
  checks.
  """

  use ExUnit.Case, async: false

  @moduletag :security

  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.RateLimiter.Limits

  @ip "203.0.113.9"
  @ipv6 "2001:db8:1:2:aaaa:bbbb:cccc:dddd"
  @email " Ada@Example.COM "

  # name => {key passed to `check/2`, the bucket keys it must charge}
  @expected %{
    signup_ip:
      {@ip, ["signup:ip:203.0.113.9:10m", "signup:ip:203.0.113.9:1h", "signup:ip:203.0.113.9:1d"]},
    signup_email:
      {@email,
       [
         "signup:email:ada@example.com:10m",
         "signup:email:ada@example.com:1h",
         "signup:email:ada@example.com:1d"
       ]},
    verification_ip:
      {@ip, ["email_verification:ip:203.0.113.9:1h", "email_verification:ip:203.0.113.9:1d"]},
    verification_user: {42, ["email_verification:user:42:1h", "email_verification:user:42:1d"]},
    signup_attempt_notice:
      {42, ["signup_attempt_notice:user:42:1h", "signup_attempt_notice:user:42:1d"]},
    social_signup_confirmation:
      {@email,
       [
         "social_signup_confirmation:email:ada@example.com:1h",
         "social_signup_confirmation:email:ada@example.com:1d"
       ]},
    password_reset_ip:
      {@ip, ["password_reset:ip:203.0.113.9:1h", "password_reset:ip:203.0.113.9:1d"]},
    password_reset_email:
      {@email,
       ["password_reset:email:ada@example.com:1h", "password_reset:email:ada@example.com:1d"]},
    email_change_verify: {@ip, ["email_change_verify:203.0.113.9"]},
    password_reset_submit: {@ip, ["password_reset_submit:203.0.113.9"]},
    verification_link: {@ip, ["verification_link:203.0.113.9"]},
    oauth_initiation: {@ip, ["oauth_initiation:203.0.113.9"]},
    oauth_callback: {@ip, ["oauth_callback:203.0.113.9"]},
    oauth_completion: {@ip, ["oauth_completion:203.0.113.9"]},
    booking_submit: {@ipv6, ["booking_submit:2001:db8:1:2::/64"]},
    booking_recipient:
      {@email, ["booking_recipient:ada@example.com:1h", "booking_recipient:ada@example.com:1d"]},
    meeting_cancel: {@ip, ["meeting_cancel:203.0.113.9"]},
    meeting_keep: {@ip, ["meeting_keep:203.0.113.9"]},
    meeting_approval: {@ip, ["meeting_approval:203.0.113.9"]},
    guest_rsvp: {@ip, ["guest_rsvp:203.0.113.9"]},
    seat_manage: {@ip, ["seat_manage:203.0.113.9"]},
    poll_register: {@ip, ["poll_register:203.0.113.9"]},
    poll_vote: {@ip, ["poll_vote:203.0.113.9"]},
    webhook: {@ip, ["webhook:203.0.113.9"]},
    stripe_webhook: {@ip, ["stripe_webhook:203.0.113.9"]},
    calendar_push: {@ip, ["calendar_push:203.0.113.9"]},
    calendar_webhook: {42, ["calendar_webhook:42"]},
    freebusy: {@ip, ["freebusy:203.0.113.9"]},
    meeting_ics: {@ip, ["meeting_ics:203.0.113.9"]},
    healthcheck: {@ip, ["healthcheck:203.0.113.9"]},
    analytics_visitor: {"abc123", ["analytics:visitor:abc123"]},
    analytics_ip: {@ip, ["analytics:ip:203.0.113.9"]},
    username_change: {"user:42", ["username_change:user:42"]},
    username_check: {"user:42", ["username_check:user:42"]},
    webhook_write: {42, ["webhook_write:42"]},
    webhook_test: {42, ["webhook_test:42"]},
    webhook_token_regen: {42, ["webhook_token_regen:42"]},
    webhook_form: {"user:42", ["webhook_form:user:42"]},
    webhook_form_validate: {"ip:203.0.113.9", ["webhook_form_validate:ip:203.0.113.9"]},
    calendar_refresh: {42, ["calendar_refresh:42"]},
    integration_write: {42, ["integration_write:42"]},
    series_rule_read: {42, ["series_rule_read:42"]},
    integration_appearance: {42, ["integration_appearance:42"]},
    calendar_visibility: {42, ["calendar_visibility:42"]},
    calendar_event_edit: {42, ["calendar_event_edit:42"]},
    calendar_ics_import: {42, ["calendar_ics_import:42"]},
    calendar_event_move:
      {42,
       [
         "calendar_event_move:42:1m",
         "calendar_event_move:42:5m",
         "calendar_event_move:42:1h",
         "calendar_event_move:42:1d"
       ]},
    meeting_type_write: {42, ["meeting_type_write:42"]},
    meeting_type_autosave: {42, ["meeting_type_autosave:42"]},
    meeting_filter: {42, ["meeting_filter:42"]},
    avatar_upload: {42, ["avatar_upload:42"]},
    theme_upload: {42, ["theme_upload:42"]},
    theme_customization: {42, ["theme_customization:42"]},
    embed_domain_update: {42, ["embed_domain_update:42"]},
    dashboard_cancel: {42, ["dashboard_cancel:42"]},
    dashboard_reschedule: {42, ["dashboard_reschedule:42"]},
    dashboard_add_guests: {42, ["dashboard_add_guests:42"]},
    dashboard_quick_add_meeting: {42, ["dashboard_quick_add_meeting:42"]},
    payment_initiation: {42, ["payment_initiation:user:42"]},
    availability_add_break: {7, ["availability:add_break:7"]},
    availability_quick_break: {7, ["availability:quick_break:7"]},
    availability_update_hours: {7, ["availability:update_hours:7"]}
  }

  setup do
    RateLimiter.clear_all()
    on_exit(&RateLimiter.clear_all/0)
    :ok
  end

  test "every limit in the table has its keys pinned here" do
    assert Enum.sort(Map.keys(Limits.all())) == Enum.sort(Map.keys(@expected))
  end

  for {name, {key, buckets}} <- @expected do
    test "#{name} charges #{inspect(buckets)}" do
      assert charged(fn -> RateLimiter.check(unquote(name), unquote(key)) end) ==
               Enum.sort(unquote(buckets))
    end
  end

  test "login charges the pair, account, source and failure buckets" do
    charged =
      charged(fn ->
        RateLimiter.check_auth_rate_limit(@email, @ip)
        RateLimiter.record_auth_attempt(@email, @ip, false)
      end)

    assert charged ==
             Enum.sort([
               "login:ada@example.com|203.0.113.9",
               "login:ada@example.com",
               "login_ip:203.0.113.9",
               "login_fail:ada@example.com|203.0.113.9"
             ])
  end

  test "connection tests charge the provider's bucket per user" do
    charged =
      charged(fn ->
        RateLimiter.check_connection_test_rate_limit(:caldav, {:user, 42})
        RateLimiter.check_connection_test_rate_limit(:custom, {:user, 42}, :video_setup)
        RateLimiter.check_connection_test_rate_limit(:discovery, {:user, 42}, :discovery)
      end)

    assert charged ==
             Enum.sort([
               "caldav_connection:user:42",
               "custom_video_connection:user:42",
               "calendar_discovery:user:42"
             ])
  end

  defp charged(fun) do
    fun.()

    Enum.sort(RateLimit.keys())
  end
end
