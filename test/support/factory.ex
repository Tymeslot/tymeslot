defmodule Tymeslot.Factory do
  @moduledoc """
  Test factories for creating test data using ExMachina.
  """

  use ExMachina.Ecto, repo: Tymeslot.Repo

  alias Ecto.UUID
  alias Tymeslot.Auth.{UserSchema, UserSessionSchema}
  alias Tymeslot.Availability.AvailabilityBreakSchema
  alias Tymeslot.Availability.AvailabilityOverrideSchema
  alias Tymeslot.Availability.WeeklyAvailabilitySchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Polls.PollTimeSlotSchema
  alias Tymeslot.Polls.PollVoteSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Password
  alias Tymeslot.Security.Token
  alias Tymeslot.Slack.SlackDeliverySchema
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Telegram.TelegramDeliverySchema
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Utils.UnguessableToken
  alias Tymeslot.Webhooks.WebhookDeliverySchema
  alias Tymeslot.Webhooks.WebhookSchema

  @spec meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  def meeting_factory do
    start_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 60, :minute)

    %MeetingSchema{
      uid: UUID.generate(),
      organizer_user: nil,
      organizer_user_id: nil,
      title: "Test Meeting",
      summary: "Test Meeting Summary",
      description: sequence(:description, &"Meeting description #{&1}"),
      start_time: start_time,
      end_time: end_time,
      duration: 60,
      location: "Test Location",
      meeting_type: "General Meeting",
      organizer_name: "Test Organizer",
      organizer_email: sequence(:organizer_email, &"organizer#{&1}@test.com"),
      attendee_name: "Test Attendee",
      attendee_email: sequence(:attendee_email, &"attendee#{&1}@test.com"),
      attendee_message: "Looking forward to our meeting!",
      attendee_timezone: "America/New_York",
      attendee_locale: "en",
      reschedule_url: sequence(:reschedule_url, &"https://example.com/reschedule/token#{&1}"),
      status: "confirmed",
      ical_sequence: 0,
      last_notified_state: %{}
    }
  end

  @spec meeting_with_status(String.t()) :: term()
  def meeting_with_status(status) do
    build(:meeting, status: status)
  end

  @spec past_meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  def past_meeting_factory do
    start_time = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 60, :minute)

    build(:meeting,
      start_time: start_time,
      end_time: end_time,
      status: "completed"
    )
  end

  @spec future_meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  def future_meeting_factory do
    start_time = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 60, :minute)

    build(:meeting,
      start_time: start_time,
      end_time: end_time,
      status: "confirmed"
    )
  end

  @spec cancelled_meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  def cancelled_meeting_factory do
    build(:meeting, status: "cancelled")
  end

  @spec pending_meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  def pending_meeting_factory do
    build(:meeting, status: "pending")
  end

  @spec user_factory() :: Tymeslot.Auth.UserSchema.t()
  def user_factory do
    %UserSchema{
      email: sequence(:email, &"user#{&1}@example.com"),
      password_hash: Password.hash_password("Password123!"),
      name: sequence(:name, &"Test User #{&1}"),
      verified_at: DateTime.utc_now(),
      provider: "email"
    }
  end

  @spec unverified_user_factory() :: Tymeslot.Auth.UserSchema.t()
  def unverified_user_factory do
    build(:user, verified_at: nil)
  end

  @spec user_session_factory() :: Tymeslot.Auth.UserSessionSchema.t()
  def user_session_factory do
    token = Token.generate_session_token()

    %UserSessionSchema{
      token: token,
      token_hash: Token.hash_token(token),
      expires_at: DateTime.truncate(DateTime.add(DateTime.utc_now(), 72, :hour), :second),
      user: build(:user)
    }
  end

  @spec profile_factory() :: Tymeslot.Profiles.ProfileSchema.t()
  def profile_factory do
    %ProfileSchema{
      timezone: Profiles.get_default_timezone(),
      buffer_minutes: 15,
      advance_booking_days: 90,
      min_advance_hours: 3,
      user: build(:user)
    }
  end

  @spec meeting_type_factory() :: Tymeslot.MeetingTypes.MeetingTypeSchema.t()
  def meeting_type_factory do
    %MeetingTypeSchema{
      name: sequence(:meeting_type_name, &"Meeting Type #{&1}"),
      description: sequence(:meeting_type_description, &"Description for meeting type #{&1}"),
      duration_minutes: 30,
      icon: "hero-bolt",
      is_active: true,
      allow_video: false,
      sort_order: 0,
      user: build(:user)
    }
  end

  @spec calendar_integration_factory() ::
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()
  def calendar_integration_factory do
    username = sequence(:calendar_username, &"user#{&1}")

    %CalendarIntegrationSchema{
      name: sequence(:calendar_name, &"Calendar #{&1}"),
      base_url: "https://calendar.example.com",
      username_encrypted: Encryption.encrypt(username),
      password_encrypted: Encryption.encrypt("password123"),
      provider: "caldav",
      provider_account_id: sequence(:cal_account_id, &"cal-account-#{&1}"),
      is_active: true,
      user: build(:user)
    }
  end

  @spec provider_calendar_event_factory() ::
          Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema.t()
  def provider_calendar_event_factory do
    now = DateTime.utc_now(:microsecond)

    %ProviderCalendarEventSchema{
      uid: sequence(:event_uid, &"event-uid-#{&1}"),
      summary: sequence(:event_summary, &"Event #{&1}"),
      provider: "google",
      provider_calendar_id: "primary",
      start_at: now,
      end_at: DateTime.add(now, 3600, :second),
      all_day: false,
      transparency: "opaque",
      status: "confirmed",
      synced_at: now,
      provider_metadata: %{},
      ical_sequence: 0,
      last_notified_state: %{},
      video_link: nil,
      calendar_integration: build(:calendar_integration)
    }
  end

  @spec video_integration_factory() :: Tymeslot.Integrations.Video.VideoIntegrationSchema.t()
  def video_integration_factory do
    api_key = sequence(:api_key, &"api_key_#{&1}")

    %VideoIntegrationSchema{
      name: sequence(:video_name, &"Video #{&1}"),
      provider: "mirotalk",
      base_url: "https://video.example.com",
      api_key_encrypted: Encryption.encrypt(api_key),
      tenant_id_encrypted: Encryption.encrypt("test-tenant-id"),
      client_id_encrypted: Encryption.encrypt("test-client-id"),
      client_secret_encrypted: Encryption.encrypt("test-client-secret"),
      teams_user_id_encrypted: Encryption.encrypt("test-teams-user-id"),
      access_token_encrypted: Encryption.encrypt("test-access-token"),
      refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
      provider_account_id: sequence(:video_account_id, &"video-account-#{&1}"),
      is_active: true,
      settings: %{},
      user: build(:user)
    }
  end

  @spec weekly_availability_factory() :: Tymeslot.Availability.WeeklyAvailabilitySchema.t()
  def weekly_availability_factory do
    %WeeklyAvailabilitySchema{
      # Monday
      day_of_week: 1,
      profile: build(:profile)
    }
  end

  @spec availability_break_factory() :: Tymeslot.Availability.AvailabilityBreakSchema.t()
  def availability_break_factory do
    %AvailabilityBreakSchema{
      start_time: ~T[12:00:00],
      end_time: ~T[13:00:00],
      label: "Lunch Break",
      sort_order: 0,
      weekly_availability: build(:weekly_availability)
    }
  end

  @spec availability_override_factory() :: Tymeslot.Availability.AvailabilityOverrideSchema.t()
  def availability_override_factory do
    %AvailabilityOverrideSchema{
      date: Date.add(Date.utc_today(), 1),
      override_type: "unavailable",
      reason: "Out of office",
      profile: build(:profile)
    }
  end

  @spec theme_customization_factory() :: Tymeslot.ThemeCustomizations.ThemeCustomizationSchema.t()
  def theme_customization_factory do
    %ThemeCustomizationSchema{
      theme_id: sequence(:theme_id, ["1", "2"]),
      color_scheme: "default",
      background_type: "gradient",
      background_value: "gradient_1",
      profile: build(:profile)
    }
  end

  @spec webhook_factory() :: Tymeslot.Webhooks.WebhookSchema.t()
  def webhook_factory do
    %WebhookSchema{
      name: sequence(:webhook_name, &"Webhook #{&1}"),
      url: sequence(:webhook_url, &"https://example.com/webhook/#{&1}"),
      events: ["meeting.created", "meeting.cancelled"],
      is_active: true,
      webhook_token_encrypted: <<1, 2, 3>>,
      user: build(:user)
    }
  end

  @spec telegram_integration_factory() :: TelegramIntegrationSchema.t()
  def telegram_integration_factory do
    %TelegramIntegrationSchema{
      name: sequence(:telegram_name, &"Telegram #{&1}"),
      bot_mode: "own",
      bot_token_encrypted: Encryption.encrypt("1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789"),
      chat_id: sequence(:telegram_chat_id, &"#{&1 + 100_000}"),
      events: ["meeting.created", "meeting.cancelled"],
      is_active: true,
      user: build(:user)
    }
  end

  @spec slack_integration_factory() :: SlackIntegrationSchema.t()
  def slack_integration_factory do
    %SlackIntegrationSchema{
      name: sequence(:slack_name, &"Slack #{&1}"),
      app_mode: "oauth",
      bot_token_encrypted: Encryption.encrypt("xoxb-test-token"),
      team_id: sequence(:slack_team_id, &"T#{&1 + 100_000}"),
      team_name: "Test Workspace",
      channel_id: sequence(:slack_channel_id, &"C#{&1 + 100_000}"),
      channel_name: "#bookings",
      events: ["meeting.created", "meeting.cancelled", "meeting.rescheduled"],
      is_active: true,
      user: build(:user)
    }
  end

  @spec telegram_delivery_factory() :: TelegramDeliverySchema.t()
  def telegram_delivery_factory do
    %TelegramDeliverySchema{
      integration: build(:telegram_integration),
      event_type: "meeting.created",
      message_text: "Test message",
      response_status: 200,
      attempt_count: 1,
      inserted_at: DateTime.utc_now()
    }
  end

  @spec slack_delivery_factory() :: SlackDeliverySchema.t()
  def slack_delivery_factory do
    %SlackDeliverySchema{
      integration: build(:slack_integration),
      event_type: "meeting.created",
      message_blocks: %{"blocks" => []},
      response_status: 200,
      attempt_count: 1,
      inserted_at: DateTime.utc_now()
    }
  end

  @spec webhook_delivery_factory() :: Tymeslot.Webhooks.WebhookDeliverySchema.t()
  def webhook_delivery_factory do
    %WebhookDeliverySchema{
      webhook: build(:webhook),
      event_type: "meeting.created",
      payload: %{"test" => true},
      response_status: 200,
      attempt_count: 1,
      inserted_at: DateTime.utc_now()
    }
  end

  @spec payment_transaction_factory() :: Tymeslot.Payments.PaymentTransactionSchema.t()
  def payment_transaction_factory do
    %PaymentTransactionSchema{
      user: build(:user),
      amount: 1000,
      product_identifier: "pro_plan",
      status: "pending",
      metadata: %{},
      stripe_id: sequence(:stripe_id, &"sess_#{&1}")
    }
  end

  @spec connect_account_factory() :: Tymeslot.MeetingPayments.ConnectAccountSchema.t()
  def connect_account_factory do
    %ConnectAccountSchema{
      stripe_account_id: sequence(:stripe_account_id, &"acct_#{&1}"),
      country: "ch",
      default_currency: "chf",
      charges_enabled: false,
      payouts_enabled: false,
      details_submitted: false,
      status: "active",
      user: build(:user)
    }
  end

  @spec booking_payment_factory() :: Tymeslot.MeetingPayments.BookingPaymentSchema.t()
  def booking_payment_factory do
    %BookingPaymentSchema{
      stripe_account_id: sequence(:bp_stripe_account_id, &"acct_#{&1}"),
      host_user_id: sequence(:bp_host_user_id, & &1),
      host_email: sequence(:bp_host_email, &"host#{&1}@test.com"),
      host_name: "Host",
      attendee_email: sequence(:bp_attendee_email, &"attendee#{&1}@test.com"),
      attendee_name: "Attendee",
      meeting_type_name: "Consult",
      booking_theme_id: "1",
      amount_cents: 5000,
      currency: "eur",
      application_fee_cents: 25,
      status: "pending",
      refunded_amount_cents: 0
    }
  end

  @spec poll_factory() :: Tymeslot.Polls.PollSchema.t()
  def poll_factory do
    %PollSchema{
      title: "Team sync",
      duration_minutes: 30,
      timezone: "Etc/UTC",
      status: :open,
      token: UnguessableToken.generate(),
      user: build(:user)
    }
  end

  @spec poll_time_slot_factory() :: Tymeslot.Polls.PollTimeSlotSchema.t()
  def poll_time_slot_factory do
    start_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 1, :hour)

    %PollTimeSlotSchema{
      start_time: start_time,
      end_time: end_time,
      position: sequence(:poll_slot_position, & &1),
      poll: build(:poll)
    }
  end

  @spec poll_participant_factory() :: Tymeslot.Polls.PollParticipantSchema.t()
  def poll_participant_factory do
    %PollParticipantSchema{
      name: sequence(:poll_participant_name, &"Participant #{&1}"),
      email: sequence(:poll_participant_email, &"participant#{&1}@example.com"),
      token: UnguessableToken.generate(),
      locale: "en",
      poll: build(:poll)
    }
  end

  @spec poll_vote_factory() :: Tymeslot.Polls.PollVoteSchema.t()
  def poll_vote_factory do
    %PollVoteSchema{
      response: :yes,
      participant: build(:poll_participant),
      time_slot: build(:poll_time_slot)
    }
  end
end
