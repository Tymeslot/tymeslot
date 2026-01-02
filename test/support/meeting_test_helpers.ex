defmodule Tymeslot.MeetingTestHelpers do
  @moduledoc """
  Shared helpers for meeting-related tests to keep setup DRY.
  """

  import Tymeslot.Factory
  alias Tymeslot.DatabaseSchemas.{MeetingSchema, ProfileSchema, UserSchema}

  @doc """
  Creates a user with a related profile and returns both.
  """
  @spec create_user_with_profile(map()) :: %{user: UserSchema.t(), profile: ProfileSchema.t()}
  def create_user_with_profile(profile_attrs \\ %{}) do
    user = insert(:user)
    profile = insert(:profile, Map.put(profile_attrs, :user, user))

    %{user: user, profile: profile}
  end

  @doc """
  Inserts a meeting for the given user with sensible defaults.

  Options:
    * `:start_offset` - seconds from now for the start time (default: 86_400 = +1 day)
    * `:duration` - seconds for duration (default: 3_600 = 1 hour)
    * any other meeting attrs to override defaults
  """
  @spec insert_meeting_for_user(UserSchema.t(), map()) :: MeetingSchema.t()
  def insert_meeting_for_user(user, attrs \\ %{}) do
    start_offset = Map.get(attrs, :start_offset, 86_400)
    duration = Map.get(attrs, :duration, 3_600)

    base_attrs = %{
      organizer_user_id: user.id,
      organizer_email: Map.get(attrs, :organizer_email, user.email),
      status: Map.get(attrs, :status, "confirmed"),
      start_time: DateTime.add(DateTime.utc_now(), start_offset, :second),
      end_time: DateTime.add(DateTime.utc_now(), start_offset + duration, :second)
    }

    merged_attrs =
      attrs
      |> Map.drop([:start_offset, :duration])
      |> Map.merge(base_attrs)

    insert(:meeting, merged_attrs)
  end

  @doc """
  Meeting params map used by appointment creation tests.
  """
  @spec build_meeting_params(UserSchema.t(), map()) :: map()
  def build_meeting_params(user, overrides \\ %{}) do
    default = %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id
    }

    Map.merge(default, overrides)
  end

  @doc """
  Form data payload used by appointment creation tests.
  """
  @spec build_form_data(map()) :: map()
  def build_form_data(overrides \\ %{}) do
    default = %{
      "name" => "Test Attendee",
      "email" => "attendee#{System.unique_integer([:positive])}@test.com",
      "message" => "Looking forward to our meeting!"
    }

    Map.merge(default, overrides)
  end
end
