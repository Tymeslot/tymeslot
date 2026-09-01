defmodule Tymeslot.Integrations.Calendar.CalDAV.Errors do
  @moduledoc """
  Interpretation of CalDAV failures: what to tell the account owner, and
  whether another attempt could possibly succeed.

  The error *vocabulary* itself is `t:Tymeslot.Integrations.Calendar.CalDAV.Base.error_reason/0`;
  this module is the behaviour layered over it. Keeping the two apart means the
  transport layer can name a failure without depending on how it is worded or
  on any retry policy.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalDAV.Base

  @doc """
  Turns an `t:Base.error_reason/0` into a sentence safe to show the account owner.

  One clause per `Base.error_reason/0` member, written for the account owner rather
  than for an operator. Anything that surfaces a CalDAV failure to a user (the
  offline queue's `sync_last_error`, for instance) routes through here so an
  inspected atom can never leak into the product. Raw terms stay in the logs,
  which is where diagnostics belong.

  String reasons (e.g. `"Unexpected status: 418"`) pass through unchanged;
  unrecognised terms collapse to a generic sentence rather than being
  inspected, so internal representations never reach the UI.

  Kept as functions rather than a module attribute: a `dgettext/2` call in an
  attribute would freeze the locale at compile time.
  """
  @spec describe_error(Base.error_reason() | term()) :: String.t()
  def describe_error(reason) when is_binary(reason), do: reason

  def describe_error({:unexpected_status, status}),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The calendar server refused the request (HTTP %{status}).",
        status: status
      )

  def describe_error(:unauthorized),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The calendar server rejected the stored credentials. Please reconnect the calendar."
      )

  def describe_error(:forbidden),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The calendar server refused access to this calendar."
      )

  def describe_error(:not_found),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The event no longer exists on the calendar server."
      )

  def describe_error(:method_not_allowed),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The calendar server answered this address but does not accept calendar requests there. Please check the server URL."
      )

  def describe_error(:precondition_failed),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The event changed on the calendar server since Tymeslot last synced it."
      )

  def describe_error(:rate_limited),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The calendar server is rate-limiting Tymeslot. Tymeslot will retry automatically."
      )

  def describe_error(:network_error),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Tymeslot could not reach the calendar server. Tymeslot will retry automatically."
      )

  def describe_error(:invalid_response),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The calendar server returned a response Tymeslot could not understand."
      )

  def describe_error(:server_error),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The calendar server reported an error. Tymeslot will retry automatically."
      )

  def describe_error(:server_unresponsive),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The calendar server did not respond. Tymeslot will retry automatically."
      )

  def describe_error(:timeout),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "The calendar server took too long to respond. Tymeslot will retry automatically."
      )

  def describe_error(_other), do: unknown_error_description()

  defp unknown_error_description do
    dgettext(
      "dashboard_calendar_providers",
      "Tymeslot could not complete the request against the calendar server."
    )
  end

  @doc """
  Tells whether a failure would fail identically on an identical retry.

  A 4xx the request cannot talk its way out of qualifies: the server understood
  the request and refused it, so replaying it costs another round trip for a
  guaranteed identical answer. Retryable conditions (timeouts, 5xx, rate
  limits) and the failures with their own handling (`:unauthorized` flags the
  integration for reconnection, `:not_found` removes the calendar path) are
  deliberately not terminal here — each has a caller that already knows what to
  do with it.

  `:method_not_allowed` needs its own clause rather than riding on the
  `{:unexpected_status, 405}` one it replaced. Without it a 405 would fall to
  the catch-all and become retryable, reinstating exactly the retry storm and
  permanent-failure admin alert `SyncCalDavCalendarWorker` discards to avoid.
  """
  @spec terminal_error?(Base.error_reason() | term()) :: boolean()
  def terminal_error?(:method_not_allowed), do: true
  def terminal_error?({:unexpected_status, status}) when status in 400..499, do: true
  def terminal_error?(_other), do: false
end
