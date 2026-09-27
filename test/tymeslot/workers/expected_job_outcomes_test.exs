defmodule Tymeslot.Workers.ExpectedJobOutcomesTest do
  @moduledoc false

  # Pins which discards and cancels each worker declares an expected end of
  # the job (left out of error tracking) and which it leaves to be recorded.
  use ExUnit.Case, async: true

  @moduletag :workers
  @moduletag :infrastructure

  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker
  alias Tymeslot.Workers

  @cases [
    {Workers.EmailWorker,
     expected: [
       "Meeting not found",
       "Meeting cancelled",
       "Meeting already started",
       "Meeting not cancelled",
       "Recipient permanently undeliverable",
       "Verification token superseded by a newer request",
       "Reset token superseded by a newer request",
       "Email change token superseded or revoked",
       "User not found",
       "host has no username",
       "poll not found",
       "poll not open",
       "User or integration not found",
       "Integration no longer needs reauth",
       "Room creation error no longer recorded",
       "Event or user not found",
       "Cached event has no timing",
       "Credentials require reauthentication",
       "One booking request leg already sent; the other failed and was requeued: :timeout"
     ],
     recorded: [
       "Email sending timed out",
       "Missing action parameter",
       "Invalid email address",
       "Unknown room creation error code",
       "Link missing or unreadable",
       "Invalid datetime: 2026-13-01",
       "Partial delivery failure: 1 of 2 failed",
       "Partial cancellation email failure: one email succeeded, retry would duplicate"
     ]},
    {Workers.CalendarEventWorker,
     expected: [
       "Meeting not found",
       "Conflicting server-side change; queued for offline replay",
       "Credentials require reauthentication"
     ],
     recorded: ["Authentication failed"]},
    {Workers.WebhookWorker,
     expected: [
       "Webhook or meeting not found",
       "Webhook is disabled",
       "Insufficient plan",
       :blocked_by_ssrf,
       :blocked_redirect,
       :too_many_redirects,
       :redirect_missing_location,
       "HTTP 404",
       "HTTP 410"
     ],
     recorded: ["Missing required parameters", "HTTP 500"]},
    {Workers.SlackWorker,
     expected: [
       "Integration or meeting not found",
       "Integration is disabled",
       "Insufficient plan",
       "token_revoked",
       "account_inactive",
       "channel_not_found",
       "webhook_url_revoked"
     ],
     recorded: ["Missing required parameters"]},
    {Workers.TelegramWorker,
     expected: [
       "Integration or meeting not found",
       "Integration is disabled",
       "Insufficient plan",
       "Bot token missing",
       "Unauthorized",
       "Bot blocked",
       "Bot kicked",
       "Chat unreachable"
     ],
     recorded: [
       "Missing required parameters",
       "Shared bot token not configured",
       "Rate limited too many times"
     ]},
    {Workers.VideoRoomWorker,
     expected: [
       "Meeting not found",
       "Meeting already started",
       "Video integration missing",
       "Video integration inactive",
       "Account cannot host video meetings"
     ],
     recorded: [
       "Authentication failed",
       "Invalid configuration",
       "Recovery attempts exhausted",
       "Recovery deadline passed",
       "Video provider unavailable — circuit breaker still open"
     ]},
    {Workers.VideoSyncWorker,
     expected: [
       "Calendar event video room not found",
       "Video integration not found",
       "Meeting not found",
       "No video integration can reach the provider room",
       "No provider video room to sync",
       "Video provider scope insufficient — reconnect required",
       "Video provider refused the stored credentials: reconnect required",
       "Video integration missing",
       "Video integration inactive",
       "Account cannot host video meetings"
     ],
     recorded: ["Authentication failed", "Invalid configuration"]},
    {Workers.VideoIntegrationDisconnectWorker,
     expected: ["Integration already removed"], recorded: []},
    {Workers.VideoTranscoder,
     expected: ["Video source no longer present"], recorded: ["ffmpeg not available"]},
    {Workers.ColourWriteBackWorker,
     expected: [:event_not_cached, :raw_ical_never_synced, :provider_has_no_event_colour],
     recorded: []},
    {ApprovalExpiryWorker, expected: ["Request answered while expiring"], recorded: []},
    {Workers.SendConnectAccountRestricted,
     expected: [
       "connect_account not found",
       "user not found",
       "Recipient permanently undeliverable"
     ],
     recorded: ["missing user_id", "missing connect_account_id", "user has no email"]},
    {Workers.SendChargeDisputeOpened,
     expected: ["booking_payment not found", "Recipient permanently undeliverable"],
     recorded: ["missing host_email", "missing booking_payment_id"]},
    {Workers.SendBookingPaymentRefunded,
     expected: ["booking_payment not found", "Recipient permanently undeliverable"],
     recorded: ["missing booking_payment_id", "missing attendee_email"]},
    {Workers.RenewWebhookChannelsWorker,
     expected: [
       "Integration not found",
       "Credentials require reauthentication",
       "Booking calendar not found — user action required"
     ],
     recorded: []},
    {Workers.RefreshOutlookCalendarWorker,
     expected: [
       "Integration not found",
       "Credentials require reauthentication",
       "Outlook sync failed transiently; the next scheduled sweep will retry"
     ],
     recorded: ["Integration is not Outlook"]},
    {Workers.ReregisterOutlookSubscriptionWorker,
     expected: ["Integration not found", "Credentials require reauthentication"], recorded: []},
    {Workers.SyncGoogleCalendarWorker,
     expected: [
       "Integration not found",
       "Credentials require reauthentication",
       "Booking calendar not found — user action required",
       "Google rejected credentials — reauthentication required",
       "Google Calendar not enabled for account: user action required"
     ],
     recorded: ["Google Calendar sync exceeded 500 pages"]},
    {Workers.SyncOutlookCalendarWorker,
     expected: [
       "Integration not found",
       "Credentials require reauthentication",
       "Microsoft Graph rejected credentials — reauthentication required"
     ],
     recorded: ["graph_resource_id required — Outlook syncs are webhook-driven"]},
    {Workers.SyncCalDavCalendarWorker,
     expected: [
       "Integration not found",
       "Credentials require reauthentication",
       "CalDAV server rejected credentials — reauthentication required",
       "CalDAV booking calendar not found — user action required",
       "CalDAV integration has no calendar selected — user action required",
       "CalDAV server returned a server error; the next scheduled sync will retry"
     ],
     recorded: ["CalDAV deletion circuit breaker refused a suspicious bulk deletion"]},
    {Workers.SyncExchangeCalendarWorker,
     expected: [
       "Integration not found",
       "Credentials require reauthentication",
       "Exchange server rejected credentials — reauthentication required",
       "Exchange integration has no addressable mailbox",
       "Exchange server returned a server error; the next scheduled sync will retry",
       "Exchange server refused the sync request: forbidden"
     ],
     recorded: []},
    {Workers.SyncIcsCalendarWorker,
     expected: ["Integration not found", "Credentials require reauthentication"],
     recorded: ["Subscription has no feed URL"]},
    {TokenRefreshJob,
     expected: [
       "Integration not found",
       "Credentials require reauthentication: invalid_grant",
       "Credentials require reauthentication: invalid_grant: Token has been expired"
     ],
     recorded: ["Credentials require reauthentication: invalid_client"]}
  ]

  for {worker, expected: expected, recorded: recorded} <- @cases do
    @worker worker
    @expected expected
    @recorded recorded

    test "#{inspect(worker)} declares its expected outcomes" do
      assert Enum.reject(@expected, &@worker.expected_outcome?/1) == []
    end

    test "#{inspect(worker)} leaves its other outcomes to be recorded" do
      assert Enum.filter(@recorded, &@worker.expected_outcome?/1) == []
      refute @worker.expected_outcome?(:some_unrelated_reason)
    end
  end
end
