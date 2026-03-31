defmodule Tymeslot.Factory do
  @moduledoc """
  Test factories for creating test data using ExMachina.
  """

  use ExMachina.Ecto, repo: Tymeslot.Repo

  alias Ecto.UUID
  alias Tymeslot.DatabaseSchemas.AvailabilityBreakSchema
  alias Tymeslot.DatabaseSchemas.AvailabilityOverrideSchema
  alias Tymeslot.DatabaseSchemas.CalendarEventCacheSchema
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.DatabaseSchemas.MeetingTypeSchema
  alias Tymeslot.DatabaseSchemas.PaymentTransactionSchema
  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.DatabaseSchemas.TelegramDeliverySchema
  alias Tymeslot.DatabaseSchemas.TelegramIntegrationSchema
  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.DatabaseSchemas.UserSchema
  alias Tymeslot.DatabaseSchemas.UserSessionSchema
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema
  alias Tymeslot.DatabaseSchemas.WebhookDeliverySchema
  alias Tymeslot.DatabaseSchemas.WebhookSchema
  alias Tymeslot.DatabaseSchemas.WeeklyAvailabilitySchema
  alias Tymeslot.Profiles
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Password
  alias Tymeslot.Security.Token

  @spec meeting_factory() :: Tymeslot.DatabaseSchemas.MeetingSchema.t()
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
      status: "confirmed"
    }
  end

  @spec meeting_with_status(String.t()) :: term()
  def meeting_with_status(status) do
    build(:meeting, status: status)
  end

  @spec past_meeting_factory() :: Tymeslot.DatabaseSchemas.MeetingSchema.t()
  def past_meeting_factory do
    start_time = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 60, :minute)

    build(:meeting,
      start_time: start_time,
      end_time: end_time,
      status: "completed"
    )
  end

  @spec future_meeting_factory() :: Tymeslot.DatabaseSchemas.MeetingSchema.t()
  def future_meeting_factory do
    start_time = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 60, :minute)

    build(:meeting,
      start_time: start_time,
      end_time: end_time,
      status: "confirmed"
    )
  end

  @spec cancelled_meeting_factory() :: Tymeslot.DatabaseSchemas.MeetingSchema.t()
  def cancelled_meeting_factory do
    build(:meeting, status: "cancelled")
  end

  @spec pending_meeting_factory() :: Tymeslot.DatabaseSchemas.MeetingSchema.t()
  def pending_meeting_factory do
    build(:meeting, status: "pending")
  end

  @spec user_factory() :: Tymeslot.DatabaseSchemas.UserSchema.t()
  def user_factory do
    %UserSchema{
      email: sequence(:email, &"user#{&1}@example.com"),
      password_hash: Password.hash_password("Password123!"),
      name: sequence(:name, &"Test User #{&1}"),
      verified_at: DateTime.utc_now(),
      provider: "email"
    }
  end

  @spec unverified_user_factory() :: Tymeslot.DatabaseSchemas.UserSchema.t()
  def unverified_user_factory do
    build(:user, verified_at: nil)
  end

  @spec user_session_factory() :: Tymeslot.DatabaseSchemas.UserSessionSchema.t()
  def user_session_factory do
    %UserSessionSchema{
      token: Token.generate_session_token(),
      expires_at: DateTime.truncate(DateTime.add(DateTime.utc_now(), 72, :hour), :second),
      user: build(:user)
    }
  end

  @spec profile_factory() :: Tymeslot.DatabaseSchemas.ProfileSchema.t()
  def profile_factory do
    %ProfileSchema{
      timezone: Profiles.get_default_timezone(),
      buffer_minutes: 15,
      advance_booking_days: 90,
      min_advance_hours: 3,
      user: build(:user)
    }
  end

  @spec meeting_type_factory() :: Tymeslot.DatabaseSchemas.MeetingTypeSchema.t()
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

  @spec calendar_integration_factory() :: Tymeslot.DatabaseSchemas.CalendarIntegrationSchema.t()
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

  @spec calendar_event_cache_factory() :: Tymeslot.DatabaseSchemas.CalendarEventCacheSchema.t()
  def calendar_event_cache_factory do
    now = DateTime.utc_now(:second)

    %CalendarEventCacheSchema{
      uid: sequence(:event_uid, &"event-uid-#{&1}"),
      title: sequence(:event_title, &"Event #{&1}"),
      start_at: now,
      end_at: DateTime.add(now, 3600, :second),
      all_day: false,
      calendar_integration: build(:calendar_integration)
    }
  end

  @spec video_integration_factory() :: Tymeslot.DatabaseSchemas.VideoIntegrationSchema.t()
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

  @spec weekly_availability_factory() :: Tymeslot.DatabaseSchemas.WeeklyAvailabilitySchema.t()
  def weekly_availability_factory do
    %WeeklyAvailabilitySchema{
      # Monday
      day_of_week: 1,
      profile: build(:profile)
    }
  end

  @spec availability_break_factory() :: Tymeslot.DatabaseSchemas.AvailabilityBreakSchema.t()
  def availability_break_factory do
    %AvailabilityBreakSchema{
      start_time: ~T[12:00:00],
      end_time: ~T[13:00:00],
      label: "Lunch Break",
      sort_order: 0,
      weekly_availability: build(:weekly_availability)
    }
  end

  @spec availability_override_factory() :: Tymeslot.DatabaseSchemas.AvailabilityOverrideSchema.t()
  def availability_override_factory do
    %AvailabilityOverrideSchema{
      date: Date.add(Date.utc_today(), 1),
      override_type: "unavailable",
      reason: "Out of office",
      profile: build(:profile)
    }
  end

  @spec theme_customization_factory() :: Tymeslot.DatabaseSchemas.ThemeCustomizationSchema.t()
  def theme_customization_factory do
    %ThemeCustomizationSchema{
      theme_id: sequence(:theme_id, ["1", "2"]),
      color_scheme: "default",
      background_type: "gradient",
      background_value: "gradient_1",
      profile: build(:profile)
    }
  end

  @spec webhook_factory() :: Tymeslot.DatabaseSchemas.WebhookSchema.t()
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

  @spec webhook_delivery_factory() :: Tymeslot.DatabaseSchemas.WebhookDeliverySchema.t()
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

  @spec payment_transaction_factory() :: Tymeslot.DatabaseSchemas.PaymentTransactionSchema.t()
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
end
