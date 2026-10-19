defmodule Tymeslot.Security.RateLimiter.Limits do
  @moduledoc """
  Every named rate limit, in one table.

  Each entry says how its bucket key is built, what it allows, and how a
  refusal is labelled:

  - `:prefix`: the start of the bucket key. Keys are `"<prefix>:<key>"` and
    must stay byte-identical across releases, since live counters are keyed on
    them; `RateLimiterKeysTest` pins every one.
  - `:scope`: what the caller's key is, and so how it becomes the last part of
    the bucket key.
    - `:source`: a client address, keyed by `RateLimiter.source_key/1` (IPv6
      by its /64).
    - `:user`: a user id, which must be a positive integer; anything else is
      refused as `{:error, :invalid_user_id}` rather than collapsed into one
      shared bucket.
    - `:id`: another record's id (an integration), refused as
      `{:error, :invalid_id}` on the same terms.
    - `:email`: an address, trimmed and downcased so its variants share one
      bucket.
    - `:key`: a string the caller has already built (an id, a hash, an actor).
  - Either `:limit` and `:window_ms` for one window, or `:tiers`, a list of
    `{label, limit, window_ms}` ordered shortest window first, each charged as
    `"<bucket>:<label>"`. No window runs past a day: the limiter keeps its hits
    in node-local ETS, which every deploy clears, so a longer one promised a
    policy nobody enforced while holding one row per hit for its whole span.
  - `:operation`: the English bucket name the log line carries.
  - `:action`: optional, the localised plural the refusal says out loud
    ("the limit of 5 signup attempts"), stored as a msgid.
  - `:log`: `false` where a refusal writes no log line here: the flood caps
    on machine-to-machine endpoints, whose refusals would otherwise write one
    warning per request under a flood; limits whose refusal has never been
    logged (form keystrokes, public poll voting, settings edits); and the
    auth limits, whose refusals the auth flows log once as a
    `rate_limit_violation` security event (`Tymeslot.Auth.RateLimit`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @minute 60_000
  @hour 60 * @minute
  @day 24 * @hour

  @payment_limits Application.compile_env(:tymeslot, :payment_rate_limits, [])

  @type scope :: :source | :user | :id | :email | :key
  @type tier :: {String.t(), pos_integer(), pos_integer()}
  @type t :: keyword()

  # Per-source tiers for the account emails: a source can only spend its own
  # budget, so these run as long as the table allows.
  @source_email_tiers [
    {"1h", 5, @hour},
    {"1d", 10, @day}
  ]

  # Per-recipient tiers: anyone who can type an address or reach an account
  # can spend these, so they never outlast a day, and every flow charges the
  # source's own bucket first so that a source over its limit spends nothing
  # of the recipient's.
  @recipient_email_tiers [
    {"1h", 5, @hour},
    {"1d", 10, @day}
  ]

  @signup_tiers [
    {"10m", 5, 10 * @minute},
    {"1h", 8, @hour},
    {"1d", 10, @day}
  ]

  @limits %{
    # Auth
    signup_ip: [
      prefix: "signup:ip",
      scope: :source,
      tiers: @signup_tiers,
      operation: "signup",
      action: dgettext_noop("errors", "signup attempts"),
      log: false
    ],
    signup_email: [
      prefix: "signup:email",
      scope: :email,
      tiers: @signup_tiers,
      operation: "signup",
      action: dgettext_noop("errors", "signup attempts"),
      log: false
    ],
    verification_ip: [
      prefix: "email_verification:ip",
      scope: :source,
      tiers: @source_email_tiers,
      operation: "email verification",
      action: dgettext_noop("errors", "verification emails"),
      log: false
    ],
    verification_user: [
      prefix: "email_verification:user",
      scope: :key,
      tiers: @recipient_email_tiers,
      operation: "email verification",
      action: dgettext_noop("errors", "verification emails"),
      log: false
    ],
    # Its own bucket, so that an attempt against an unverified account never
    # spends that account's own resend allowance.
    signup_attempt_notice: [
      prefix: "signup_attempt_notice:user",
      scope: :key,
      tiers: @recipient_email_tiers,
      operation: "signup attempt notice",
      action: dgettext_noop("errors", "verification emails"),
      log: false
    ],
    social_signup_confirmation: [
      prefix: "social_signup_confirmation:email",
      scope: :email,
      tiers: @recipient_email_tiers,
      operation: "social signup confirmation",
      action: dgettext_noop("errors", "verification emails"),
      log: false
    ],
    password_reset_ip: [
      prefix: "password_reset:ip",
      scope: :source,
      tiers: @source_email_tiers,
      operation: "password reset",
      action: dgettext_noop("errors", "password reset requests"),
      log: false
    ],
    password_reset_email: [
      prefix: "password_reset:email",
      scope: :email,
      tiers: @recipient_email_tiers,
      operation: "password reset",
      action: dgettext_noop("errors", "password reset requests"),
      log: false
    ],
    email_change_verify: [
      prefix: "email_change_verify",
      scope: :source,
      limit: 30,
      window_ms: @minute,
      operation: "email change verification",
      log: false
    ],
    # The reset token is the only secret on that form, and each attempt pays
    # for a bcrypt hash.
    password_reset_submit: [
      prefix: "password_reset_submit",
      scope: :source,
      limit: 30,
      window_ms: @minute,
      operation: "password reset submission",
      log: false
    ],
    verification_link: [
      prefix: "verification_link",
      scope: :source,
      limit: 30,
      window_ms: @minute,
      operation: "email verification link",
      log: false
    ],

    # OAuth sign-in
    oauth_initiation: [
      prefix: "oauth_initiation",
      scope: :source,
      limit: 10,
      window_ms: 10 * @minute,
      operation: "OAuth initiation",
      log: false
    ],
    oauth_callback: [
      prefix: "oauth_callback",
      scope: :source,
      limit: 20,
      window_ms: 2 * @minute,
      operation: "OAuth callback",
      log: false
    ],
    oauth_completion: [
      prefix: "oauth_completion",
      scope: :source,
      limit: 6,
      window_ms: 20 * @minute,
      operation: "OAuth completion",
      log: false
    ],

    # Bookings and the public booking links
    booking_submit: [
      prefix: "booking_submit",
      scope: :source,
      limit: 10,
      window_ms: 20 * @minute,
      operation: "booking submission"
    ],
    # The per-source bucket does not stop someone rotating addresses to bomb
    # one mailbox with confirmations; this caps the bookings that can target a
    # single attendee address, whatever the source.
    booking_recipient: [
      prefix: "booking_recipient",
      scope: :email,
      tiers: [{"1h", 5, @hour}, {"1d", 20, @day}],
      operation: "booking",
      action: dgettext_noop("errors", "bookings")
    ],
    meeting_cancel: [
      prefix: "meeting_cancel",
      scope: :source,
      limit: 10,
      window_ms: 10 * @minute,
      operation: "meeting cancellation"
    ],
    meeting_keep: [
      prefix: "meeting_keep",
      scope: :source,
      limit: 10,
      window_ms: 10 * @minute,
      operation: "meeting keep"
    ],
    # Keyed on the client rather than the meeting: the token already binds a
    # link to one request, so what is worth bounding is somebody working
    # through guessed or harvested links.
    meeting_approval: [
      prefix: "meeting_approval",
      scope: :source,
      limit: 20,
      window_ms: 10 * @minute,
      operation: "booking request answer"
    ],
    # Counts both the landing page and the response, keyed on the client for
    # the same reason as `:meeting_approval`.
    guest_rsvp: [
      prefix: "guest_rsvp",
      scope: :source,
      limit: 60,
      window_ms: @minute,
      operation: "guest RSVP"
    ],
    # A group participant's cancel landing page, cancellation and reschedule
    # redirect.
    seat_manage: [
      prefix: "seat_manage",
      scope: :source,
      limit: 60,
      window_ms: @minute,
      operation: "seat management"
    ],
    # A poll's public write actions, sized to a handful of legitimate
    # submissions a minute.
    poll_register: [
      prefix: "poll_register",
      scope: :source,
      limit: 5,
      window_ms: @minute,
      operation: "poll registration",
      log: false
    ],
    poll_vote: [
      prefix: "poll_vote",
      scope: :source,
      limit: 10,
      window_ms: @minute,
      operation: "poll vote",
      log: false
    ],

    # Machine-to-machine endpoints
    webhook: [
      prefix: "webhook",
      scope: :source,
      limit: 100,
      window_ms: 10 * @minute,
      operation: "webhook",
      log: false
    ],
    # Stripe delivers every event from a small published pool of addresses,
    # so a bucket as tight as `:webhook` would refuse a burst and delay the
    # event a paid booking is waiting on. Signatures are verified after this,
    # so it only bounds unsigned floods.
    stripe_webhook: [
      prefix: "stripe_webhook",
      scope: :source,
      limit: 1_000,
      window_ms: @minute,
      operation: "Stripe webhook",
      log: false
    ],
    # Google and Microsoft Graph deliver every tenant's notifications from a
    # small pool of their own addresses, so one key here aggregates the whole
    # instance's push traffic: a flood cap, not a fair-use ceiling. A limit
    # tight enough to bound one tenant would throttle all of them, and Graph
    # drops a subscription whose endpoint keeps refusing it.
    # `:calendar_webhook` is what bounds one tenant's work.
    calendar_push: [
      prefix: "calendar_push",
      scope: :source,
      limit: 1_000,
      window_ms: @minute,
      operation: "calendar push",
      log: false
    ],
    # Reads of a Google or Outlook series' master by the sync, one GET each
    # (`Tymeslot.Integrations.Calendar.SeriesRules`), charged before every
    # read whatever it answers, so a run of failures spends the budget too.
    series_rule_read: [
      prefix: "series_rule_read",
      scope: :id,
      limit: 50,
      window_ms: 10 * @minute,
      operation: "series rule read",
      log: false
    ],
    calendar_webhook: [
      prefix: "calendar_webhook",
      scope: :id,
      limit: 60,
      window_ms: @minute,
      operation: "calendar webhook",
      log: false
    ],
    freebusy: [
      prefix: "freebusy",
      scope: :source,
      limit: 60,
      window_ms: @minute,
      operation: "free/busy feed",
      log: false
    ],
    meeting_ics: [
      prefix: "meeting_ics",
      scope: :source,
      limit: 60,
      window_ms: @minute,
      operation: "meeting calendar feed",
      log: false
    ],
    healthcheck: [
      prefix: "healthcheck",
      scope: :source,
      limit: 30,
      window_ms: @minute,
      operation: "healthcheck",
      log: false
    ],
    # Analytics ingestion: a real visitor cannot click 30 times a minute, and
    # the per-source cap catches clients that cycle user agents to defeat the
    # visitor fingerprint. Refusals drop events silently.
    analytics_visitor: [
      prefix: "analytics:visitor",
      scope: :key,
      limit: 30,
      window_ms: @minute,
      operation: "analytics event",
      log: false
    ],
    analytics_ip: [
      prefix: "analytics:ip",
      scope: :source,
      limit: 300,
      window_ms: @minute,
      operation: "analytics event",
      log: false
    ],

    # Profile
    username_change: [
      prefix: "username_change",
      scope: :key,
      limit: 6,
      window_ms: 2 * @hour,
      operation: "username change",
      log: false
    ],
    username_check: [
      prefix: "username_check",
      scope: :key,
      limit: 60,
      window_ms: 2 * @minute,
      operation: "username check",
      log: false
    ],

    # Dashboard, per organiser
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
    ],
    payment_initiation: [
      prefix: "payment_initiation:user",
      scope: :user,
      limit: Keyword.get(@payment_limits, :max_attempts, 5),
      window_ms: Keyword.get(@payment_limits, :window_ms, 10 * @minute),
      operation: "payment initiation",
      log: false
    ],
    # Keyed on the schedule being edited.
    availability_add_break: [
      prefix: "availability:add_break",
      scope: :key,
      limit: 8,
      window_ms: @minute,
      operation: "availability break",
      log: false
    ],
    availability_quick_break: [
      prefix: "availability:quick_break",
      scope: :key,
      limit: 8,
      window_ms: @minute,
      operation: "availability quick break",
      log: false
    ],
    availability_update_hours: [
      prefix: "availability:update_hours",
      scope: :key,
      limit: 10,
      window_ms: 10_000,
      operation: "availability hours update",
      log: false
    ]
  }

  @type name :: atom()

  @doc "The entry for `name`; raises on a name that is not in the table."
  @spec fetch!(name()) :: t()
  def fetch!(name), do: Map.fetch!(@limits, name)

  @doc "Every entry, by name."
  @spec all() :: %{name() => t()}
  def all, do: @limits
end
