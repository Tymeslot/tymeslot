defmodule Tymeslot.Factory do
  @moduledoc """
  Test factories for creating test data using ExMachina.
  """

  use ExMachina.Ecto, repo: Tymeslot.Repo
  use Tymeslot.Factory.IntegrationDeliveryFactories
  use Tymeslot.Factory.MeetingPaymentFactories
  use Tymeslot.Factory.PollFactories
  use Tymeslot.Factory.VideoIntegrationFactories

  alias Ecto.UUID
  alias Tymeslot.Auth.{UserSchema, UserSessionSchema}
  alias Tymeslot.Availability.AvailabilityBreakSchema
  alias Tymeslot.Availability.AvailabilityOverrideSchema
  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Availability.TimeOffPeriodSchema
  alias Tymeslot.Availability.WeeklyAvailabilitySchema
  alias Tymeslot.BookingPages.BookingPageMeetingTypeSchema
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Factory.TokenHash
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Password
  alias Tymeslot.Security.Token
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Venues.VenueSchema

  # Every factory user carries the same password, so hashing it per insert buys
  # nothing: bcrypt is deliberately slow, and the suite builds users in the
  # thousands. Hashing once at compile time keeps `verify_password/2` working
  # against "Password123!" while dropping the per-insert cost to a map lookup.
  @default_password "Password123!"
  @default_password_hash Password.hash_password(@default_password)

  @spec meeting_factory(map()) :: Tymeslot.Meetings.MeetingSchema.t()
  # Like a meeting created through its changeset, the calendar is known to show
  # the meeting's own end until a sync says otherwise; pass
  # `seen_calendar_end_time: nil` for a meeting that predates that record.
  def meeting_factory(attrs) do
    start_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 60, :minute)

    %MeetingSchema{
      uid: UUID.generate(),
      calendar_uid: UUID.generate(),
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
      status: :confirmed,
      ical_sequence: 0,
      last_notified_state: %{}
    }
    |> merge_attributes(attrs)
    |> evaluate_lazy_attributes()
    |> then(fn meeting ->
      if Map.has_key?(attrs, :seen_calendar_end_time),
        do: meeting,
        else: %{meeting | seen_calendar_end_time: meeting.end_time}
    end)
  end

  @spec meeting_with_status(String.t()) :: term()
  def meeting_with_status(status) do
    build(:meeting, status: status)
  end

  @doc """
  A booking held for email verification, its 30-minute hold just begun.
  Pass `verification_deadline_at` to place the deadline elsewhere.
  """
  @spec awaiting_verification_meeting_factory(map()) :: Tymeslot.Meetings.MeetingSchema.t()
  def awaiting_verification_meeting_factory(attrs) do
    %{
      status: :awaiting_verification,
      verification_deadline_at: DateTime.add(DateTime.utc_now(:second), 30, :minute)
    }
    |> Map.merge(Map.new(attrs))
    |> meeting_factory()
  end

  @spec past_meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  def past_meeting_factory do
    start_time = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 60, :minute)

    build(:meeting,
      start_time: start_time,
      end_time: end_time,
      status: :completed
    )
  end

  @spec future_meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  def future_meeting_factory do
    start_time = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 60, :minute)

    build(:meeting,
      start_time: start_time,
      end_time: end_time,
      status: :confirmed
    )
  end

  @spec cancelled_meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  def cancelled_meeting_factory do
    build(:meeting, status: :cancelled)
  end

  @spec pending_meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  def pending_meeting_factory do
    build(:meeting, status: :pending)
  end

  @spec group_meeting_factory() :: Tymeslot.Meetings.MeetingSchema.t()
  # A group meeting's people are its participant rows; its own attendee
  # columns are always empty.
  def group_meeting_factory do
    build(:meeting,
      capacity: 2,
      attendee_name: nil,
      attendee_email: nil,
      attendee_message: nil,
      attendee_timezone: nil,
      attendee_locale: nil
    )
  end

  @spec participant_factory(map()) :: Tymeslot.Meetings.ParticipantSchema.t()
  def participant_factory(attrs) do
    %ParticipantSchema{
      meeting: build(:meeting),
      name: sequence(:participant_name, &"Participant #{&1}"),
      email: sequence(:participant_email, &"participant#{&1}@test.com"),
      timezone: "Europe/Zurich",
      locale: "en",
      custom_field_answers: %{},
      management_token: Token.generate(32)
    }
    |> merge_attributes(attrs)
    |> evaluate_lazy_attributes()
    |> TokenHash.put(:management_token, :management_token_hash)
  end

  @doc "A weekly two-session booking series without its sessions; pass `organizer_user`."
  @spec booking_series_factory() :: SeriesSchema.t()
  def booking_series_factory do
    %SeriesSchema{
      uid: UUID.generate(),
      organizer_user: build(:user),
      mode: :recurring,
      frequency: :weekly,
      interval: 1,
      occurrences_count: 2,
      attendee_name: "Ada Lovelace",
      attendee_email: "ada@example.com",
      attendee_timezone: "Etc/UTC",
      attendee_locale: "en"
    }
  end

  @spec user_factory() :: Tymeslot.Auth.UserSchema.t()
  def user_factory do
    %UserSchema{
      email: sequence(:email, &"user#{&1}@example.com"),
      password_hash: @default_password_hash,
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
    token = Token.generate()

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

  @doc """
  A video location for a meeting type, bound to `integration`, or to a list
  of integrations the booker picks between (the first is the default).

  A booking's video room follows the location the booker chose, not the
  request, so a test that expects a room has to give the meeting type
  somewhere video to be held:

      insert(:meeting_type, user: user, locations: [video_location(integration)])
  """
  @spec video_location(map() | [map()], keyword()) :: LocationOption.t()
  def video_location(integrations, attrs \\ []) do
    struct!(
      %LocationOption{
        id: UUID.generate(),
        kind: :video,
        label: "Video call",
        video_integration_ids: integrations |> List.wrap() |> Enum.map(& &1.id),
        position: 0
      },
      attrs
    )
  end

  @doc """
  An in-person location for a meeting type, listing `venues` in the order
  given; the first is the one a booker who changes nothing gets. With no
  venues it is the "address arranged after booking" location.

      insert(:meeting_type, user: user, locations: [in_person_location([office])])
  """
  @spec in_person_location([map()], keyword()) :: LocationOption.t()
  def in_person_location(venues \\ [], attrs \\ []) do
    struct!(
      %LocationOption{
        id: UUID.generate(),
        kind: :in_person,
        label: "In person",
        venue_ids: Enum.map(venues, & &1.id),
        position: 0
      },
      attrs
    )
  end

  @spec venue_factory() :: Tymeslot.Venues.VenueSchema.t()
  def venue_factory do
    %VenueSchema{
      name: sequence(:venue_name, &"Office #{&1}"),
      description: "12 High Street",
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

  @spec availability_schedule_factory() ::
          Tymeslot.Availability.AvailabilityScheduleSchema.t()
  def availability_schedule_factory do
    %AvailabilityScheduleSchema{
      name: sequence(:availability_schedule_name, &"Schedule #{&1}"),
      is_default: false,
      buffer_before_minutes: 15,
      buffer_after_minutes: 15,
      min_advance_hours: 3,
      advance_booking_days: 90,
      profile: build(:profile)
    }
  end

  @spec weekly_availability_factory() :: Tymeslot.Availability.WeeklyAvailabilitySchema.t()
  def weekly_availability_factory do
    %WeeklyAvailabilitySchema{
      # Monday
      day_of_week: 1,
      schedule: build(:availability_schedule)
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
      override_type: :unavailable,
      reason: "Out of office",
      schedule: build(:availability_schedule)
    }
  end

  @spec time_off_period_factory() :: Tymeslot.Availability.TimeOffPeriodSchema.t()
  def time_off_period_factory do
    starts_on = Date.add(Date.utc_today(), 7)

    %TimeOffPeriodSchema{
      starts_on: starts_on,
      ends_on: Date.add(starts_on, 6),
      start_time: nil,
      end_time: nil,
      label: "Holiday",
      profile: build(:profile)
    }
  end

  @default_theme_settings %{
    "color_scheme" => "default",
    "background_type" => "gradient",
    "background_value" => "gradient_1"
  }
  @theme_setting_keys ~w(color_scheme custom_palette_seed background_type background_value
                         background_image_path background_video_path)a

  # Takes the settings flat, beside the columns, as the changeset's attrs do:
  # `insert(:theme_customization, background_type: "video")`. A nil setting is
  # left out of the stored map, as a save leaves it out.
  @spec theme_customization_factory(map()) ::
          Tymeslot.ThemeCustomizations.ThemeCustomizationSchema.t()
  def theme_customization_factory(attrs) do
    {settings, attrs} = attrs |> Map.new() |> Map.split(@theme_setting_keys)

    settings =
      for {key, value} <- settings,
          value != nil,
          into: @default_theme_settings,
          do: {Atom.to_string(key), value}

    %ThemeCustomizationSchema{
      theme_id: sequence(:theme_id, ["1", "2"]),
      settings: settings,
      profile: build(:profile)
    }
    |> merge_attributes(attrs)
    |> evaluate_lazy_attributes()
  end

  @spec booking_page_factory() :: Tymeslot.BookingPages.BookingPageSchema.t()
  def booking_page_factory do
    %BookingPageSchema{
      name: sequence(:booking_page_name, &"Page #{&1}"),
      slug: sequence(:booking_page_slug, &"page-#{&1}"),
      booking_theme: "1",
      profile: build(:profile)
    }
  end

  @spec booking_page_meeting_type_factory() ::
          Tymeslot.BookingPages.BookingPageMeetingTypeSchema.t()
  def booking_page_meeting_type_factory do
    %BookingPageMeetingTypeSchema{
      booking_page: build(:booking_page),
      meeting_type: build(:meeting_type)
    }
  end

  @spec payment_transaction_factory() :: Tymeslot.Payments.PaymentTransactionSchema.t()
  def payment_transaction_factory do
    %PaymentTransactionSchema{
      user: build(:user),
      amount: 1000,
      product_identifier: "pro_plan",
      status: :pending,
      metadata: %{},
      stripe_id: sequence(:stripe_id, &"sess_#{&1}")
    }
  end
end
