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
alias Tymeslot.Mocks.StripeBehaviours.{
  StripeChargeBehaviour,
  StripeCustomerBehaviour,
  StripeSessionBehaviour,
  StripeSubscriptionBehaviour,
  StripeWebhookBehaviour
}

# --- Calendar ---
Mox.defmock(Tymeslot.CalendarMock, for: Tymeslot.Integrations.Calendar.CalendarBehaviour)

Mox.defmock(Tymeslot.RadicaleClientMock,
  for: Tymeslot.Integrations.Calendar.CalDAV.ClientBehaviour
)

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
Mox.defmock(Tymeslot.MiroTalkAPIMock,
  for: Tymeslot.Integrations.Video.MiroTalk.MiroTalkClientBehaviour
)

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

Mox.defmock(Tymeslot.Auth.OAuth.ClientMock, for: Tymeslot.Auth.OAuth.ClientBehaviour)
Mox.defmock(Tymeslot.Auth.OAuth.HelperMock, for: Tymeslot.Auth.OAuth.HelperBehaviour)
Mox.defmock(Tymeslot.Auth.SessionMock, for: Tymeslot.Infrastructure.SessionBehaviour)
Mox.defmock(Tymeslot.Auth.VerificationMock, for: Tymeslot.Infrastructure.VerificationBehaviour)
Mox.defmock(Tymeslot.Auth.UserBroadcasterMock, for: Tymeslot.Auth.Behaviours.UserBroadcaster)

# --- Payments ---
Mox.defmock(Tymeslot.Payments.StripeMock, for: Tymeslot.Payments.Behaviours.StripeProvider)

Mox.defmock(Tymeslot.Payments.SubscriptionManagerMock,
  for: Tymeslot.Payments.Behaviours.SubscriptionManager
)

Mox.defmock(Tymeslot.MeetingPayments.StripeAdapterMock,
  for: Tymeslot.MeetingPayments.StripeAdapter
)

# Stripe internal mocks for testing the wrapper (behaviours in
# Tymeslot.Mocks.StripeBehaviours).
Mox.defmock(StripeCustomerMock, for: StripeCustomerBehaviour)
Mox.defmock(StripeSessionMock, for: StripeSessionBehaviour)
Mox.defmock(StripeSubscriptionMock, for: StripeSubscriptionBehaviour)
Mox.defmock(StripeChargeMock, for: StripeChargeBehaviour)
Mox.defmock(StripeWebhookMock, for: StripeWebhookBehaviour)
