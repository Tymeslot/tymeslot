defmodule Tymeslot.Security.RateLimiter.Dashboard do
  @moduledoc false

  alias Tymeslot.Security.RateLimiter.Helpers

  @spec check_webhook_write(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_webhook_write(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "webhook_write:#{user_id}",
      30,
      1_800_000,
      "webhook write",
      to_string(user_id)
    )
  end

  def check_webhook_write(user_id), do: Helpers.invalid_user_id("webhook write", user_id)

  @spec check_webhook_test(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_webhook_test(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "webhook_test:#{user_id}",
      30,
      300_000,
      "webhook test",
      to_string(user_id)
    )
  end

  def check_webhook_test(user_id), do: Helpers.invalid_user_id("webhook test", user_id)

  @spec check_webhook_token_regen(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_webhook_token_regen(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "webhook_token_regen:#{user_id}",
      10,
      3_600_000,
      "webhook token regeneration",
      to_string(user_id)
    )
  end

  def check_webhook_token_regen(user_id),
    do: Helpers.invalid_user_id("webhook token regeneration", user_id)

  @spec check_calendar_refresh(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_calendar_refresh(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "calendar_refresh:#{user_id}",
      10,
      600_000,
      "calendar refresh",
      to_string(user_id)
    )
  end

  def check_calendar_refresh(user_id), do: Helpers.invalid_user_id("calendar refresh", user_id)

  @spec check_integration_write(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_integration_write(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "integration_write:#{user_id}",
      30,
      1_800_000,
      "integration write",
      to_string(user_id)
    )
  end

  def check_integration_write(user_id),
    do: Helpers.invalid_user_id("integration write", user_id)

  @spec check_meeting_type_write(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_meeting_type_write(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "meeting_type_write:#{user_id}",
      60,
      1_800_000,
      "meeting type write",
      to_string(user_id)
    )
  end

  def check_meeting_type_write(user_id),
    do: Helpers.invalid_user_id("meeting type write", user_id)

  @spec check_avatar_upload(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_avatar_upload(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "avatar_upload:#{user_id}",
      20,
      3_600_000,
      "avatar upload",
      to_string(user_id)
    )
  end

  def check_avatar_upload(user_id), do: Helpers.invalid_user_id("avatar upload", user_id)

  @spec check_cancel(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_cancel(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "dashboard_cancel:#{user_id}",
      20,
      600_000,
      "meeting cancellation",
      to_string(user_id)
    )
  end

  def check_cancel(user_id), do: Helpers.invalid_user_id("meeting cancellation", user_id)

  @spec check_reschedule(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_reschedule(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "dashboard_reschedule:#{user_id}",
      20,
      600_000,
      "reschedule request",
      to_string(user_id)
    )
  end

  def check_reschedule(user_id), do: Helpers.invalid_user_id("reschedule request", user_id)

  @spec check_meeting_filter(integer()) :: :ok | {:error, :rate_limited, String.t()}
  def check_meeting_filter(user_id) do
    Helpers.check_with_logging(
      "meeting_filter:#{user_id}",
      100,
      300_000,
      "meeting filter",
      to_string(user_id)
    )
  end

  @spec check_theme_customization(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_theme_customization(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "theme_customization:#{user_id}",
      150,
      300_000,
      "theme customization",
      to_string(user_id)
    )
  end

  def check_theme_customization(user_id),
    do: Helpers.invalid_user_id("theme customization", user_id)

  @spec check_payment_initiation(integer()) :: :ok | {:error, :rate_limited}
  def check_payment_initiation(user_id) do
    config = Application.get_env(:tymeslot, :payment_rate_limits, [])
    max_attempts = Keyword.get(config, :max_attempts, 5)
    window_ms = Keyword.get(config, :window_ms, 600_000)
    Helpers.check_rate_limit("payment_initiation:user:#{user_id}", max_attempts, window_ms)
  end
end
