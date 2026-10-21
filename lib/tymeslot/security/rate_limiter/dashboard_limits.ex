defmodule Tymeslot.Security.RateLimiter.DashboardLimits do
  @moduledoc """
  The rate limits for the dashboard's write actions, per organiser: webhooks,
  integrations, calendar edits, meeting types, uploads, theme and embed
  settings, and the meeting actions. Split out of `Limits` to keep that table
  under the module size limit; `Limits` merges these entries into its own, and
  its moduledoc describes the shape of an entry.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @minute 60_000
  @hour 60 * @minute
  @day 24 * @hour

  @limits %{
    webhook_write: [
      prefix: "webhook_write",
      scope: :user,
      limit: 30,
      window_ms: 30 * @minute,
      operation: "webhook write"
    ],
    webhook_test: [
      prefix: "webhook_test",
      scope: :user,
      limit: 30,
      window_ms: 5 * @minute,
      operation: "webhook test"
    ],
    webhook_token_regen: [
      prefix: "webhook_token_regen",
      scope: :user,
      limit: 10,
      window_ms: @hour,
      operation: "webhook token regeneration"
    ],
    # The webhook form, keyed per actor (`"user:<id>"` or `"ip:<source>"`) so
    # that one organiser can never spend another's budget. Validation fires
    # on every keystroke, so it has a wider budget than the save.
    webhook_form: [
      prefix: "webhook_form",
      scope: :key,
      limit: 60,
      window_ms: @minute,
      operation: "webhook form",
      log: false
    ],
    webhook_form_validate: [
      prefix: "webhook_form_validate",
      scope: :key,
      limit: 180,
      window_ms: @minute,
      operation: "webhook form validation",
      log: false
    ],
    calendar_refresh: [
      prefix: "calendar_refresh",
      scope: :user,
      limit: 10,
      window_ms: 10 * @minute,
      operation: "calendar refresh"
    ],
    integration_write: [
      prefix: "integration_write",
      scope: :user,
      limit: 30,
      window_ms: 30 * @minute,
      operation: "integration write"
    ],
    # How an integration is presented (its name and event colour): one column
    # on a row the user owns, driven by a swatch grid where clicking through
    # colours is how the control is meant to be used. It would exhaust the
    # connection-sized `:integration_write` budget in under a minute.
    integration_appearance: [
      prefix: "integration_appearance",
      scope: :user,
      limit: 150,
      window_ms: 30 * @minute,
      operation: "integration appearance"
    ],
    # Deliberately the loosest dashboard budget. Toggling a calendar is a view
    # control an organiser may click repeatedly while scanning a busy week:
    # 300 in ten minutes is one click every two seconds for the whole window.
    # It exists to stop a script hammering the write, not to cap normal use.
    calendar_visibility: [
      prefix: "calendar_visibility",
      scope: :user,
      limit: 300,
      window_ms: 10 * @minute,
      operation: "calendar visibility"
    ],
    calendar_event_edit: [
      prefix: "calendar_event_edit",
      scope: :user,
      limit: 30,
      window_ms: 5 * @minute,
      operation: "calendar event edit"
    ],
    calendar_ics_import: [
      prefix: "calendar_ics_import",
      scope: :user,
      limit: 5,
      window_ms: @hour,
      operation: "calendar ics import"
    ],
    calendar_event_move: [
      prefix: "calendar_event_move",
      scope: :user,
      tiers: [
        {"1m", 3, @minute},
        {"5m", 5, 5 * @minute},
        {"1h", 15, @hour},
        {"1d", 30, @day}
      ],
      operation: "calendar event move",
      action: dgettext_noop("errors", "calendar event moves")
    ],
    meeting_type_write: [
      prefix: "meeting_type_write",
      scope: :user,
      limit: 60,
      window_ms: 30 * @minute,
      operation: "meeting type write"
    ],
    meeting_type_autosave: [
      prefix: "meeting_type_autosave",
      scope: :user,
      limit: 600,
      window_ms: 30 * @minute,
      operation: "meeting type autosave"
    ],
    meeting_filter: [
      prefix: "meeting_filter",
      scope: :user,
      limit: 100,
      window_ms: 5 * @minute,
      operation: "meeting filter"
    ],
    avatar_upload: [
      prefix: "avatar_upload",
      scope: :user,
      limit: 20,
      window_ms: @hour,
      operation: "avatar upload"
    ],
    # Shared across every theme upload field: video encoding is the
    # expensive part, and a budget per field would multiply the ceiling.
    theme_upload: [
      prefix: "theme_upload",
      scope: :user,
      limit: 5,
      window_ms: 10 * @minute,
      operation: "theme asset upload",
      log: false
    ],
    theme_customization: [
      prefix: "theme_customization",
      scope: :user,
      limit: 150,
      window_ms: 5 * @minute,
      operation: "theme customization"
    ],
    embed_domain_update: [
      prefix: "embed_domain_update",
      scope: :user,
      limit: 10,
      window_ms: @hour,
      operation: "embed domain update"
    ],
    dashboard_cancel: [
      prefix: "dashboard_cancel",
      scope: :user,
      limit: 20,
      window_ms: 10 * @minute,
      operation: "meeting cancellation"
    ],
    dashboard_reschedule: [
      prefix: "dashboard_reschedule",
      scope: :user,
      limit: 20,
      window_ms: 10 * @minute,
      operation: "reschedule request"
    ],
    dashboard_add_guests: [
      prefix: "dashboard_add_guests",
      scope: :user,
      limit: 20,
      window_ms: 10 * @minute,
      operation: "guest invitation"
    ],
    dashboard_quick_add_meeting: [
      prefix: "dashboard_quick_add_meeting",
      scope: :user,
      limit: 20,
      window_ms: 10 * @minute,
      operation: "quick add meeting"
    ]
  }

  @doc "The dashboard entries, by name."
  @spec all() :: %{atom() => keyword()}
  def all, do: @limits
end
