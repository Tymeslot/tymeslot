defmodule Tymeslot.Security.RateLimiter do
  @moduledoc """
  Rate limiter backed by Hammer (ETS sliding window).
  """

  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter.Auth
  alias Tymeslot.Security.RateLimiter.Bookings
  alias Tymeslot.Security.RateLimiter.Calendar
  alias Tymeslot.Security.RateLimiter.Dashboard
  alias Tymeslot.Security.RateLimiter.Helpers
  alias Tymeslot.Security.RateLimiter.Integrations
  alias Tymeslot.Security.RateLimiter.OAuth
  alias Tymeslot.Security.RateLimiter.Profile

  @type bucket_key :: String.t()
  @type rate_check_result :: {:allow, pos_integer()} | {:deny, pos_integer()}

  @doc """
  Check rate limit for a given bucket key.
  Returns {:allow, count} if within limits, {:deny, limit} if exceeded.
  """
  @spec check_rate(bucket_key(), pos_integer(), pos_integer()) :: rate_check_result()
  def check_rate(bucket_key, window_ms, limit) do
    Helpers.check_rate(bucket_key, window_ms, limit)
  end

  @doc """
  Clear rate limit data for a specific bucket key.

  Test-only — bypasses Hammer's internal state management.
  """
  @spec clear_bucket(bucket_key()) :: :ok
  def clear_bucket(bucket_key) do
    :ets.match_delete(RateLimit, {{bucket_key, :_}, :_})
    :ok
  end

  @doc """
  Clear all rate limit data.

  Test-only — bypasses Hammer's internal state management.
  """
  @spec clear_all() :: :ok
  def clear_all do
    :ets.delete_all_objects(RateLimit)
    :ok
  end

  @doc """
  Check rate limit for authentication.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_rate_limit(bucket_key(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def check_rate_limit(bucket_key, limit, window_ms) do
    Helpers.check_rate_limit(bucket_key, limit, window_ms)
  end

  # Auth

  @doc """
  Rate limit authentication attempts with account lockout.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.
  """
  @spec check_auth_rate_limit(String.t(), String.t() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_auth_rate_limit(email, ip \\ nil), do: Auth.check_auth(email, ip)

  @doc """
  Record authentication attempt result for lockout tracking.
  """
  @spec record_auth_attempt(String.t(), boolean()) :: :ok | {:error, atom(), String.t()}
  def record_auth_attempt(email, success), do: Auth.record_attempt(email, success)

  @doc """
  Rate limit signup attempts per email and per IP with multi-window buckets.
  """
  @spec check_signup_rate_limit(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_signup_rate_limit(email, ip), do: Auth.check_signup(email, ip)

  @doc """
  Rate limit email verification/resend attempts per user and per IP.
  """
  @spec check_verification_rate_limit(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_verification_rate_limit(user_id, ip), do: Auth.check_verification(user_id, ip)

  @doc """
  Rate limit password reset requests per email and per IP.
  """
  @spec check_password_reset_rate_limit(
          String.t(),
          String.t() | :inet.ip_address() | nil
        ) :: :ok | {:error, :rate_limited, String.t()}
  def check_password_reset_rate_limit(email, ip), do: Auth.check_password_reset(email, ip)

  # OAuth

  @doc """
  Rate limit OAuth initiation attempts (GitHub, Google signup).
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_oauth_initiation_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_oauth_initiation_rate_limit(ip_address), do: OAuth.check_initiation(ip_address)

  @doc """
  Rate limit OAuth callback processing.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_oauth_callback_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_oauth_callback_rate_limit(ip_address), do: OAuth.check_callback(ip_address)

  @doc """
  Rate limit OAuth completion form submissions.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_oauth_completion_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_oauth_completion_rate_limit(ip_address), do: OAuth.check_completion(ip_address)

  @doc """
  Rate limit OAuth registration completion in LiveView.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_oauth_registration_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_oauth_registration_rate_limit(ip_address), do: OAuth.check_registration(ip_address)

  # Integrations

  @doc """
  Rate limit a provider's connection-test attempts, in the bucket the
  provider draws its budget from (`:caldav`, `:nextcloud`, `:mirotalk`,
  `:custom`, `:oauth`, or `:discovery` for calendar discovery, which is
  metered exactly like a connection test but isn't tied to any one
  provider's own bucket).

  Limit: 20 tests per 10 minutes per scope (30 for `:discovery`), except
  `:custom` — which probes an arbitrary user-supplied host — at 5 per 10
  minutes. The bucket is always charged to `{:user, user_id}` — an
  interactive "Test connection" click or integration setup. A scheduled
  background health probe never reaches this function at all: see
  `Tymeslot.Integrations.Shared.ConnectionProbe`'s `:background` clause
  (and its moduledoc) for why background probing is unmetered by
  construction rather than charged to some other bucket.

  Only `Tymeslot.Integrations.Shared.ConnectionProbe` calls this directly —
  `CredoChecks.RateLimiterBoundary` enforces that boundary mechanically.

  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.
  """
  @spec check_connection_test_rate_limit(
          Integrations.connection_bucket(),
          Integrations.connection_scope() | nil
        ) :: :ok | {:error, :rate_limited, String.t()} | {:error, :unattributable}
  def check_connection_test_rate_limit(bucket, scope),
    do: Integrations.check_connection_test(bucket, scope)

  # Bookings

  @doc """
  Rate limit webhook endpoint.

  Limit: 100 requests per 10 minutes per IP

  ## Parameters
    * `client_ip` - The client IP address

  ## Returns
    * `:ok` - Request allowed
    * `{:error, :rate_limited}` - Rate limit exceeded
  """
  @spec check_webhook_rate_limit(String.t()) :: :ok | {:error, :rate_limited}
  def check_webhook_rate_limit(client_ip), do: Bookings.check_webhook_endpoint(client_ip)

  @doc """
  Rate limit booking submission attempts.
  Returns {:allow, count} if allowed, {:deny, limit} if exceeded.
  """
  @spec check_booking_submission_limit(String.t()) :: rate_check_result()
  def check_booking_submission_limit(client_ip), do: Bookings.check_booking_submission(client_ip)

  @doc """
  Rate limit booking submissions by attendee email (recipient of the
  confirmation email). Complements the per-IP limit to stop email
  amplification from an attacker rotating source IPs against one mailbox.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.
  """
  @spec check_booking_recipient_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_booking_recipient_limit(email), do: Bookings.check_booking_recipient(email)

  @doc """
  Rate limit meeting cancellation attempts.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Prevents abuse by limiting how often meeting cancellation actions can be performed.
  Generous limit of 10 cancellations per 10 minutes per IP to avoid impacting legitimate users.
  """
  @spec check_meeting_cancel_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_meeting_cancel_rate_limit(client_ip), do: Bookings.check_meeting_cancel(client_ip)

  @doc """
  Rate limit meeting keep/uncancel attempts.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Prevents abuse by limiting how often meeting keep actions can be performed.
  Generous limit of 10 keep actions per 10 minutes per IP to avoid impacting legitimate users.
  """
  @spec check_meeting_keep_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_meeting_keep_rate_limit(client_ip), do: Bookings.check_meeting_keep(client_ip)

  # Profile

  @doc """
  Rate limit username change attempts.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_username_change_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited}
  def check_username_change_rate_limit(identifier),
    do: Profile.check_username_change(identifier)

  @doc """
  Rate limit username availability checks.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_username_check_rate_limit(String.t()) :: :ok | {:error, :rate_limited}
  def check_username_check_rate_limit(identifier),
    do: Profile.check_username_check(identifier)

  # Dashboard

  @doc """
  Rate limit theme customization changes (color schemes, backgrounds).
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded,
  or {:error, :invalid_user_id} if user_id is invalid.

  Prevents abuse by limiting how often theme customization changes can be made.

  ## Rate Limit Configuration

  - Limit: 150 changes per 5 minutes per user
  - Rationale: Allows legitimate customization workflow where users try multiple
    colors/backgrounds rapidly to find their preferred design (~30-40 changes in
    active session). Adjusted from initial 50 to reduce false positives based on
    expected UX patterns.
  - Scope: All theme changes (colors + backgrounds) share same bucket to prevent
    overall abuse while allowing natural exploration workflow.

  ## Error Responses

  - `:ok` - Request allowed
  - `{:error, :rate_limited, message}` - Rate limit exceeded
  - `{:error, :invalid_user_id}` - Invalid user_id provided
  """
  @spec check_theme_customization_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_theme_customization_rate_limit(user_id),
    do: Dashboard.check_theme_customization(user_id)

  @doc """
  Rate limit meeting filter changes in dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Prevents abuse by limiting how often filter changes can be made.
  Generous limit of 100 filter changes per 5 minutes per user to allow normal browsing.
  """
  @spec check_meeting_filter_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_meeting_filter_rate_limit(user_id), do: Dashboard.check_meeting_filter(user_id)

  @doc """
  Rate limit webhook create/update operations from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 30 writes per 30 minutes per user.
  """
  @spec check_webhook_write_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_webhook_write_rate_limit(user_id), do: Dashboard.check_webhook_write(user_id)

  @doc """
  Rate limit webhook test-connection operations from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 30 tests per 5 minutes per user.
  """
  @spec check_webhook_test_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_webhook_test_rate_limit(user_id), do: Dashboard.check_webhook_test(user_id)

  @doc """
  Rate limit webhook security token regeneration from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 10 regenerations per hour per user.
  """
  @spec check_webhook_token_regen_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_webhook_token_regen_rate_limit(user_id),
    do: Dashboard.check_webhook_token_regen(user_id)

  @doc """
  Rate limit the "refresh all calendars" operation from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 5 refreshes per 2 minutes per user.
  """
  @spec check_calendar_refresh_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_calendar_refresh_rate_limit(user_id),
    do: Dashboard.check_calendar_refresh(user_id)

  @doc """
  Rate limit inline edits to calendar events (title, location, description, time).
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 30 edits per 5 minutes per user.
  """
  @spec check_calendar_event_edit_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_calendar_event_edit_rate_limit(user_id),
    do: Calendar.check_event_edit(user_id)

  @doc """
  Rate limit moving events between calendars (delete + create).
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Uses tiered windows so a burst trips the short window first (1 min cooldown)
  rather than locking the user out for a long period:
  - 3 per minute
  - 5 per 5 minutes
  - 15 per hour
  - 30 per day
  """
  @spec check_calendar_event_move_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_calendar_event_move_rate_limit(user_id),
    do: Calendar.check_event_move(user_id)

  @doc """
  Rate limit calendar and video integration write operations (add/toggle) from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 30 writes per 30 minutes per user.
  """
  @spec check_integration_write_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_integration_write_rate_limit(user_id),
    do: Dashboard.check_integration_write(user_id)

  @doc """
  Rate limit changes to how an integration is *presented* — its name and the
  colour its events are painted in.

  A separate, more permissive bucket from `check_integration_write_rate_limit/1`
  because the two meter different things. That one guards writes that reach a
  provider or move credentials around, where 30 in half an hour is already
  generous. These write one column on a row the user owns and touch nothing
  outside Tymeslot, and they are driven by a swatch grid: comparing colours by
  clicking through them is how the control is meant to be used, and it would
  exhaust a connection-sized budget in under a minute.

  Limit: 150 writes per 30 minutes per user.
  """
  @spec check_integration_appearance_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_integration_appearance_rate_limit(user_id),
    do: Dashboard.check_integration_appearance(user_id)

  @doc """
  Rate limit meeting type write operations (create, update, toggle, delete, reorder) from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 60 writes per 30 minutes per user.
  """
  @spec check_meeting_type_write_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_meeting_type_write_rate_limit(user_id),
    do: Dashboard.check_meeting_type_write(user_id)

  @doc """
  Rate limit meeting type auto-save writes from the meeting type editor.

  Auto-save persists on every change, so this bucket is far more permissive
  than the manual write limit — it must never trip during a legitimate
  editing session while still capping a runaway or scripted client.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 600 writes per 30 minutes per user.
  """
  @spec check_meeting_type_autosave_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_meeting_type_autosave_rate_limit(user_id),
    do: Dashboard.check_meeting_type_autosave(user_id)

  @doc """
  Rate limit avatar upload and delete operations from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 20 uploads per hour per user.
  """
  @spec check_avatar_upload_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_avatar_upload_rate_limit(user_id), do: Dashboard.check_avatar_upload(user_id)

  @doc """
  Rate limit owner-side meeting cancellation from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 20 cancellations per 10 minutes per user.
  """
  @spec check_dashboard_cancel_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_dashboard_cancel_rate_limit(user_id), do: Dashboard.check_cancel(user_id)

  @doc """
  Rate limit owner-side reschedule request sending from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 20 reschedule requests per 10 minutes per user.
  """
  @spec check_dashboard_reschedule_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_dashboard_reschedule_rate_limit(user_id), do: Dashboard.check_reschedule(user_id)

  @doc """
  Rate limit payment initiation attempts.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.

  Prevents abuse by limiting how often users can initiate payment or subscription checkouts.
  This protects against API spam and potential DoS attacks via the payment endpoint.
  """
  @spec check_payment_initiation_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited} | {:error, :invalid_user_id}
  def check_payment_initiation_rate_limit(user_id),
    do: Dashboard.check_payment_initiation(user_id)

  @doc "Rate limit calendar webhook notifications per integration (60/min)."
  @spec check_calendar_webhook_rate_limit(integer()) :: :ok | {:error, :rate_limited}
  def check_calendar_webhook_rate_limit(id), do: Calendar.check_webhook(id)
end
