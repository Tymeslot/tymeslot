defmodule Tymeslot.Security.RateLimiterRefusalLoggingTest do
  @moduledoc """
  Which limits write a "Rate limit exceeded" warning when they refuse.

  Most do. The silent ones are flood caps on machine-to-machine endpoints,
  limits whose refusal was never logged (form keystrokes, public poll voting,
  settings edits), the auth limits, whose refusal the auth flows log once
  as a security event, and the series rule read budget, whose refusal ends
  the sync run's reads with one line of its own; a second line per refusal
  would bury the ones worth reading.
  """

  use ExUnit.Case, async: false

  @moduletag :security

  import ExUnit.CaptureLog

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.RateLimiter.Limits

  @quiet ~w(
    analytics_ip analytics_visitor availability_add_break availability_quick_break
    availability_update_hours calendar_push calendar_webhook freebusy healthcheck
    meeting_ics payment_initiation poll_register poll_vote stripe_webhook theme_upload
    username_change username_check webhook webhook_form webhook_form_validate
  )a

  # The auth flows log these refusals once themselves, as a security event.
  @audited_by_auth ~w(
    email_change_verify oauth_callback oauth_completion oauth_initiation
    password_reset_email password_reset_ip password_reset_submit
    signup_attempt_notice signup_email signup_ip social_signup_confirmation
    verification_ip verification_link verification_user
  )a

  # A sync run stops reading series rules on the first refusal and logs
  # that once.
  @logged_by_sync ~w(series_rule_read)a

  @silent @quiet ++ @audited_by_auth ++ @logged_by_sync

  setup do
    RateLimiter.clear_all()
    on_exit(&RateLimiter.clear_all/0)
    :ok
  end

  test "exactly these limits refuse without logging" do
    silent = for {name, entry} <- Limits.all(), entry[:log] == false, do: name
    assert Enum.sort(silent) == Enum.sort(@silent)
  end

  for name <- @silent do
    test "#{name} refuses without a warning" do
      assert refusal_log(unquote(name)) == ""
    end
  end

  test "a logged limit warns when it refuses" do
    assert refusal_log(:meeting_cancel) =~ "Rate limit exceeded"
  end

  # Spends the limit's whole budget quietly, then captures what the refusal
  # itself logs.
  defp refusal_log(name) do
    entry = Limits.fetch!(name)
    key = key_for(entry[:scope])

    for _i <- 1..smallest_limit(entry), do: :ok = RateLimiter.check(name, key)

    capture_log([level: :warning], fn ->
      assert {:error, :rate_limited, _message} = RateLimiter.check(name, key)
    end)
  end

  defp smallest_limit(entry) do
    case entry[:tiers] do
      nil -> entry[:limit]
      tiers -> tiers |> Enum.map(&elem(&1, 1)) |> Enum.min()
    end
  end

  defp key_for(:source), do: "203.0.113.9"
  defp key_for(scope) when scope in [:user, :id], do: 42
  defp key_for(:email), do: "ada@example.com"
  defp key_for(:key), do: "user:42"
end
