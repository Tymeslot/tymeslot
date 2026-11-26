# Mox mock definitions, shared by every suite that runs against Core.
#
# These live in a compiled support file (not in test_helper.exs) so they are
# defined exactly once, at compile time, and are available to every project
# that depends on :tymeslot in the :test env. Hand-maintaining the same
# defmocks in each project's test_helper.exs behind `Code.ensure_loaded?/1`
# guards was a standing drift hazard.
#
# A file with bare top-level `Mox.defmock/2` calls is the idiomatic Mox pattern:
# each call generates its mock module as compiled output.

# --- Calendar ---
Mox.defmock(Tymeslot.CalendarMock, for: Tymeslot.Integrations.Calendar.CalendarBehaviour)

Mox.defmock(GoogleCalendarAPIMock,
  for: Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour
)

Mox.defmock(OutlookCalendarAPIMock,
  for: Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour
)

Mox.defmock(Tymeslot.GoogleOAuthHelperMock,
  for: Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
)

Mox.defmock(Tymeslot.OutlookOAuthHelperMock,
  for: Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
)

# --- Video ---
Mox.defmock(Tymeslot.TeamsOAuthHelperMock,
  for: Tymeslot.Integrations.Video.Teams.TeamsOAuthHelperBehaviour
)

Mox.defmock(Tymeslot.ZoomOAuthHelperMock,
  for: Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour
)

# --- Infrastructure / auth ---
Mox.defmock(Tymeslot.EmailServiceMock, for: Tymeslot.Emails.EmailServiceBehaviour)
Mox.defmock(Tymeslot.HTTPClientMock, for: Tymeslot.Infrastructure.HTTPClientBehaviour)
Mox.defmock(Tymeslot.DnsResolverMock, for: Tymeslot.Security.DnsResolutionBehaviour)
Mox.defmock(Tymeslot.Media.TranscoderMock, for: Tymeslot.Media.TranscoderBehaviour)

Mox.defmock(Tymeslot.Integrations.HealthCheckMock,
  for: Tymeslot.Integrations.HealthCheck.HealthCheckBehaviour
)

# --- Payments ---
Mox.defmock(Tymeslot.Payments.SubscriptionManagerMock,
  for: Tymeslot.Payments.Behaviours.SubscriptionManager
)
