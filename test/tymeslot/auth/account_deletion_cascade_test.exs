defmodule Tymeslot.Auth.AccountDeletionCascadeTest do
  @moduledoc """
  Enumerates every database-level association that a user owns and pins
  the intended outcome of `UserQueries.delete_user/1` for each. The
  cascades are set in migrations (`on_delete: :delete_all` or
  `:nilify_all`), so any reversal — an accidental `:restrict`, a new
  table wired in without an FK cascade, a `nilify_all` silently
  reverting to app-level control — would leave orphan rows or PII
  after a user exercises their GDPR right-to-delete. This test makes
  that invariant explicit across the full association graph.

  Each assertion carries the intended outcome inline: either
  **deleted** (row removed) or **anonymised** (row remains but no
  longer references the deleted user). Adding a new user-keyed table
  should add a new row here.

  Out of scope:
    * Oban jobs keyed on user_id — production does not currently
      cancel-on-delete. The plan's "scheduled jobs cancelled, not
      discarded silently" bullet is documented as a follow-up
      (job left in queue → fails at execution time with no user
      row).
  """

  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Announcements.UserSeenAnnouncementSchema
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Auth.UserSessionSchema
  alias Tymeslot.Availability.AvailabilityBreakSchema
  alias Tymeslot.Availability.AvailabilityOverrideSchema
  alias Tymeslot.Availability.WeeklyAvailabilitySchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Telegram.TelegramDeliverySchema
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Webhooks.WebhookDeliverySchema
  alias Tymeslot.Webhooks.WebhookSchema

  import Tymeslot.Factory

  describe "delete_user/1 full cascade" do
    test "removes every user-keyed row directly FK'd to users and all profile-chained rows" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      # Direct user_id FKs with on_delete: :delete_all
      session = insert(:user_session, user: user)
      meeting_type = insert(:meeting_type, user: user)
      calendar_integration = insert(:calendar_integration, user: user)
      video_integration = insert(:video_integration, user: user)
      telegram_integration = insert(:telegram_integration, user: user)
      webhook = insert(:webhook, user: user)
      payment_transaction = insert(:payment_transaction, user: user)
      meeting = insert(:meeting, organizer_user: user, organizer_email: user.email)

      # Transitive cascade via webhook_id -> delete_all
      webhook_delivery = insert(:webhook_delivery, webhook: webhook)

      # Transitive cascade via calendar_integration_id -> delete_all
      provider_event =
        insert(:provider_calendar_event, calendar_integration: calendar_integration)

      # Transitive cascade via integration_id -> delete_all
      telegram_delivery = insert(:telegram_delivery, integration: telegram_integration)

      # Direct user_id FK with on_delete: :delete_all (no factory — seed directly)
      {:ok, calendar_prefs} =
        %CalendarPreferencesSchema{}
        |> CalendarPreferencesSchema.changeset(%{user_id: user.id})
        |> Repo.insert()

      # Profile-chained :delete_all
      weekly = insert(:weekly_availability, profile: profile)
      override = insert(:availability_override, profile: profile)

      # Transitive cascade via weekly_availability_id -> delete_all
      availability_break = insert(:availability_break, weekly_availability: weekly)

      theme =
        insert(:theme_customization,
          profile: profile,
          theme_id: "1",
          color_scheme: "default",
          background_type: "gradient",
          background_value: "gradient_1"
        )

      # integration_health_states is user_id :delete_all by migration
      # 20260406095819. Seed one directly since it has no public factory.
      {:ok, health_state} =
        %IntegrationHealthStateSchema{}
        |> IntegrationHealthStateSchema.changeset(%{
          integration_type: "calendar",
          integration_id: calendar_integration.id,
          user_id: user.id,
          status: "healthy",
          backoff_ms: 1_800_000
        })
        |> Repo.insert()

      # user_seen_announcements is user_id :delete_all by migration
      # 20260508090605. Seed one directly since it has no public factory.
      {:ok, seen_announcement} =
        %UserSeenAnnouncementSchema{}
        |> UserSeenAnnouncementSchema.changeset(%{
          user_id: user.id,
          announcement_key: "cascade_probe",
          seen_at: ~U[2026-05-01 00:00:00Z]
        })
        |> Repo.insert()

      # Sanity: every seeded row is present before the delete.
      assert Repo.get(UserSchema, user.id)
      assert Repo.get(ProfileSchema, profile.id)
      assert Repo.get(UserSessionSchema, session.id)
      assert Repo.get(MeetingTypeSchema, meeting_type.id)
      assert Repo.get(CalendarIntegrationSchema, calendar_integration.id)
      assert Repo.get(VideoIntegrationSchema, video_integration.id)
      assert Repo.get(TelegramIntegrationSchema, telegram_integration.id)
      assert Repo.get(WebhookSchema, webhook.id)
      assert Repo.get(WebhookDeliverySchema, webhook_delivery.id)
      assert Repo.get(PaymentTransactionSchema, payment_transaction.id)
      assert Repo.get(MeetingSchema, meeting.id)
      assert Repo.get(WeeklyAvailabilitySchema, weekly.id)
      assert Repo.get(AvailabilityOverrideSchema, override.id)
      assert Repo.get(ThemeCustomizationSchema, theme.id)
      assert Repo.get(IntegrationHealthStateSchema, health_state.id)
      assert Repo.get(UserSeenAnnouncementSchema, seen_announcement.id)
      assert Repo.get(CalendarPreferencesSchema, calendar_prefs.id)
      assert Repo.get(ProviderCalendarEventSchema, provider_event.id)
      assert Repo.get(TelegramDeliverySchema, telegram_delivery.id)
      assert Repo.get(AvailabilityBreakSchema, availability_break.id)

      assert {:ok, _deleted} = UserQueries.delete_user(user)

      # User row gone.
      refute Repo.get(UserSchema, user.id)

      # Direct :delete_all cascades — row must be gone.
      refute Repo.get(ProfileSchema, profile.id),
             "profile: expected delete-cascade via user_id FK (`on_delete: :delete_all`)"

      refute Repo.get(UserSessionSchema, session.id),
             "user_session: expected delete-cascade"

      refute Repo.get(MeetingTypeSchema, meeting_type.id),
             "meeting_type: expected delete-cascade"

      refute Repo.get(CalendarIntegrationSchema, calendar_integration.id),
             "calendar_integration: expected delete-cascade"

      refute Repo.get(VideoIntegrationSchema, video_integration.id),
             "video_integration: expected delete-cascade"

      refute Repo.get(TelegramIntegrationSchema, telegram_integration.id),
             "telegram_integration: expected delete-cascade"

      refute Repo.get(WebhookSchema, webhook.id),
             "webhook: expected delete-cascade"

      refute Repo.get(PaymentTransactionSchema, payment_transaction.id),
             "payment_transaction: expected delete-cascade"

      refute Repo.get(MeetingSchema, meeting.id),
             "meeting: expected delete-cascade via organizer_user_id " <>
               "(migration 20260226120000 changed this from :nilify_all to :delete_all — " <>
               "a reversal would leak organiser PII in scheduled meetings)"

      refute Repo.get(IntegrationHealthStateSchema, health_state.id),
             "integration_health_state: expected delete-cascade"

      refute Repo.get(UserSeenAnnouncementSchema, seen_announcement.id),
             "user_seen_announcement: expected delete-cascade via user_id FK (`on_delete: :delete_all`)"

      # Transitive :delete_all: webhook_delivery -> webhook -> user.
      refute Repo.get(WebhookDeliverySchema, webhook_delivery.id),
             "webhook_delivery: expected transitive delete-cascade through its webhook"

      # Direct :delete_all via user_id.
      refute Repo.get(CalendarPreferencesSchema, calendar_prefs.id),
             "calendar_preferences: expected delete-cascade via user_id FK (`on_delete: :delete_all`)"

      # Profile-chained :delete_all.
      refute Repo.get(WeeklyAvailabilitySchema, weekly.id),
             "weekly_availability: expected transitive delete-cascade through its profile"

      refute Repo.get(AvailabilityOverrideSchema, override.id),
             "availability_override: expected transitive delete-cascade through its profile"

      refute Repo.get(ThemeCustomizationSchema, theme.id),
             "theme_customization: expected transitive delete-cascade through its profile"

      # Transitive :delete_all: provider_event -> calendar_integration -> user.
      refute Repo.get(ProviderCalendarEventSchema, provider_event.id),
             "provider_calendar_event: expected transitive delete-cascade through its calendar_integration"

      # Transitive :delete_all: telegram_delivery -> telegram_integration -> user.
      refute Repo.get(TelegramDeliverySchema, telegram_delivery.id),
             "telegram_delivery: expected transitive delete-cascade through its telegram_integration"

      # Transitive :delete_all: availability_break -> weekly_availability -> profile -> user.
      refute Repo.get(AvailabilityBreakSchema, availability_break.id),
             "availability_break: expected transitive delete-cascade through its weekly_availability"
    end

    test "does not touch rows belonging to another user" do
      # Co-tenant isolation: deleting user A must only cascade to
      # associations that point at user A. A concurrent user B's
      # integration/meeting/webhook data must be untouched.
      user_a = insert(:user)
      user_b = insert(:user)
      profile_b = insert(:profile, user: user_b)

      meeting_b = insert(:meeting, organizer_user: user_b, organizer_email: user_b.email)
      calendar_b = insert(:calendar_integration, user: user_b)
      theme_b = insert(:theme_customization, profile: profile_b)

      assert {:ok, _deleted} = UserQueries.delete_user(user_a)

      assert Repo.get(UserSchema, user_b.id)
      assert Repo.get(MeetingSchema, meeting_b.id)
      assert Repo.get(CalendarIntegrationSchema, calendar_b.id)
      assert Repo.get(ThemeCustomizationSchema, theme_b.id)
    end
  end
end
