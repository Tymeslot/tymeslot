defmodule Tymeslot.Integrations.Calendar.SyncErrorMessagesTest do
  # The rule every writer of a calendar integration's `sync_error` follows:
  # it stores a msgid exactly, so the integration card can translate it, and
  # never text built from the failure (a status, an exception's message, a
  # URL). Each writer's wording function is run over the reasons that reach
  # it, including the ones it does not recognise.
  #
  # The CalDAV sync worker stores `CalDAV.Errors.describe_error/1`; the
  # Exchange sync worker words its own refusals (a SOAP fault, an unreadable
  # free/busy answer, a guarded empty result) and hands every transport
  # failure to `describe_error/1`; the subscription worker stores
  # `Ics.Feed.sync_error_message/1`; and the token refresh job's fixed
  # sentence is pinned in its own test.
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.Errors, as: CalDAVErrors
  alias Tymeslot.Integrations.Calendar.Ics.Feed
  alias Tymeslot.Test.KnownMsgid
  alias Tymeslot.Workers.SyncExchangeCalendarWorker

  @caldav_and_exchange_reasons [
    :unauthorized,
    :forbidden,
    :not_found,
    :method_not_allowed,
    :precondition_failed,
    :rate_limited,
    :network_error,
    :invalid_response,
    :response_too_large,
    :server_error,
    :service_unavailable,
    :server_unresponsive,
    :timeout,
    {:unexpected_status, 418},
    "Failed to parse calendar query response",
    "No calendars configured",
    %RuntimeError{message: "boom"}
  ]

  @exchange_reasons [
    {:empty_feed_with_populated_cache, "busy_only"},
    {:empty_feed_with_populated_cache, "events"},
    {:soap_fault, "ErrorInternalServerError"},
    :no_response_code,
    {:response_code, "ErrorAccessDenied"},
    {:free_busy_view_type, "None"},
    :timeout,
    {:unexpected_status, 503}
  ]

  @subscription_reasons [
    :unauthorised,
    :not_found,
    :too_large,
    :invalid_ics,
    :too_many_redirects,
    :missing_url,
    {:http_status, 503},
    {:transport, :econnrefused},
    {:blocked, :private_ip},
    :empty_feed_with_populated_cache,
    %RuntimeError{message: "boom"}
  ]

  for reason <- @caldav_and_exchange_reasons do
    @reason reason

    test "CalDAV and Exchange store a msgid for #{inspect(reason)}" do
      assert_msgid(CalDAVErrors.describe_error(@reason))
    end
  end

  for reason <- @exchange_reasons do
    @reason reason

    test "Exchange stores a msgid for #{inspect(reason)}" do
      assert_msgid(SyncExchangeCalendarWorker.sync_error_message(@reason))
    end
  end

  for reason <- @subscription_reasons do
    @reason reason

    test "a calendar subscription stores a msgid for #{inspect(reason)}" do
      assert_msgid(Feed.sync_error_message(@reason))
    end
  end

  # A job running in another locale still stores the English msgid, which
  # the card then translates into the owner's locale.
  test "the stored sentence does not depend on the writing process's locale" do
    Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
      assert_msgid(CalDAVErrors.describe_error(:timeout))
      assert_msgid(SyncExchangeCalendarWorker.sync_error_message({:soap_fault, "Error"}))
      assert_msgid(Feed.sync_error_message(:not_found))
      assert_msgid(Feed.sync_error_message({:http_status, 503}))
    end)
  end

  defp assert_msgid(stored) do
    assert KnownMsgid.known?(stored), "not a msgid the card can translate: #{inspect(stored)}"
  end
end
