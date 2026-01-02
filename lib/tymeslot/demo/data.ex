defmodule Tymeslot.Demo.Data do
  @moduledoc """
  Hardcoded demo data for showcasing scheduling themes.

  This module contains all the demo data needed to run the scheduling
  demos without requiring database entries.
  """

  @doc """
  Returns demo profile data for a given theme ID.
  """
  @spec get_demo_profile(String.t()) :: map() | nil
  def get_demo_profile("1") do
    %{
      id: 999_001,
      user_id: 999_001,
      username: "demo-theme-1",
      full_name: "Sarah Rodriguez",
      timezone: "America/New_York",
      buffer_minutes: 15,
      advance_booking_days: 90,
      min_advance_hours: 24,
      avatar: "/images/content/demo-profiles/sarah-rodriguez.webp",
      booking_theme: "1",
      has_custom_theme: true,
      user: %{
        id: 999_001,
        name: "Sarah Rodriguez",
        email: "demo-theme-1@example.com"
      },
      theme_customization: %Tymeslot.DatabaseSchemas.ThemeCustomizationSchema{
        id: 999_001,
        profile_id: 999_001,
        theme_id: "1",
        color_scheme: "turquoise",
        background_type: "video",
        background_value: "preset:space",
        background_image_path: nil,
        background_video_path: nil
      }
    }
  end

  def get_demo_profile("2") do
    %{
      id: 999_002,
      user_id: 999_002,
      username: "demo-theme-2",
      full_name: "Marcus Chen",
      timezone: "America/Los_Angeles",
      buffer_minutes: 30,
      advance_booking_days: 60,
      min_advance_hours: 48,
      avatar: "/images/content/demo-profiles/marcus-chen.webp",
      booking_theme: "2",
      has_custom_theme: true,
      user: %{
        id: 999_002,
        name: "Marcus Chen",
        email: "demo-theme-2@example.com"
      },
      theme_customization: %Tymeslot.DatabaseSchemas.ThemeCustomizationSchema{
        id: 999_002,
        profile_id: 999_002,
        theme_id: "2",
        color_scheme: "sunset",
        background_type: "video",
        background_value: "preset:leaves",
        background_image_path: nil,
        background_video_path: nil
      }
    }
  end

  def get_demo_profile(_), do: nil

  @doc """
  Returns demo profile by username.
  """
  @spec get_demo_profile_by_username(String.t()) :: map() | nil
  def get_demo_profile_by_username("demo-theme-1"), do: get_demo_profile("1")
  def get_demo_profile_by_username("demo-theme-2"), do: get_demo_profile("2")
  def get_demo_profile_by_username(_), do: nil

  @doc """
  Returns meeting types for a demo user.
  """
  @spec get_demo_meeting_types(integer()) :: [map()]
  def get_demo_meeting_types(user_id) when user_id == 999_001 do
    [
      %{
        id: 999_001,
        user_id: 999_001,
        name: "Quick Chat",
        description: "A brief 15-minute conversation",
        duration_minutes: 15,
        icon: "hero-chat-bubble-left-right",
        is_active: true,
        allow_video: true,
        video_integration_id: 999_001,
        sort_order: 1
      },
      %{
        id: 999_002,
        user_id: 999_001,
        name: "Strategy Session",
        description: "In-depth 30-minute strategy discussion",
        duration_minutes: 30,
        icon: "hero-light-bulb",
        is_active: true,
        allow_video: true,
        video_integration_id: 999_001,
        sort_order: 2
      },
      %{
        id: 999_004,
        user_id: 999_001,
        name: "Deep Dive",
        description: "Extended 60-minute working session",
        duration_minutes: 60,
        icon: "hero-rocket-launch",
        is_active: true,
        allow_video: true,
        video_integration_id: 999_001,
        sort_order: 3
      }
    ]
  end

  def get_demo_meeting_types(user_id) when user_id == 999_002 do
    [
      %{
        id: 999_005,
        user_id: 999_002,
        name: "Coffee Chat",
        description: "Casual 20-minute virtual coffee",
        duration_minutes: 20,
        icon: "hero-chat-bubble-left-right",
        is_active: true,
        allow_video: true,
        video_integration_id: 999_002,
        sort_order: 1
      },
      %{
        id: 999_006,
        user_id: 999_002,
        name: "Project Review",
        description: "30-minute project status review",
        duration_minutes: 30,
        icon: "hero-clipboard-document-check",
        is_active: true,
        allow_video: true,
        video_integration_id: 999_002,
        sort_order: 2
      },
      %{
        id: 999_007,
        user_id: 999_002,
        name: "Workshop",
        description: "Interactive 90-minute workshop",
        duration_minutes: 90,
        icon: "hero-presentation-chart-line",
        is_active: true,
        allow_video: true,
        video_integration_id: 999_002,
        sort_order: 3
      }
    ]
  end

  def get_demo_meeting_types(_), do: []

  @doc """
  Returns demo video integration data.
  """
  @spec get_demo_video_integration(integer()) :: map() | nil
  def get_demo_video_integration(999_001) do
    %{
      id: 999_001,
      user_id: 999_001,
      provider: "mirotalk",
      is_active: true,
      settings: %{
        "room_prefix" => "demo-quill"
      }
    }
  end

  def get_demo_video_integration(999_002) do
    %{
      id: 999_002,
      user_id: 999_002,
      provider: "google_meet",
      is_active: true,
      settings: %{
        "account_email" => "demo@example.com"
      }
    }
  end

  def get_demo_video_integration(_), do: nil

  @doc """
  Returns demo weekly availability.
  """
  @spec get_demo_weekly_availability(integer()) :: map()
  def get_demo_weekly_availability(profile_id) do
    # Standard business hours Mon-Fri 9am-5pm in the user's timezone
    %{
      id: profile_id,
      profile_id: profile_id,
      monday_enabled: true,
      monday_start: ~T[09:00:00],
      monday_end: ~T[17:00:00],
      tuesday_enabled: true,
      tuesday_start: ~T[09:00:00],
      tuesday_end: ~T[17:00:00],
      wednesday_enabled: true,
      wednesday_start: ~T[09:00:00],
      wednesday_end: ~T[17:00:00],
      thursday_enabled: true,
      thursday_start: ~T[09:00:00],
      thursday_end: ~T[17:00:00],
      friday_enabled: true,
      friday_start: ~T[09:00:00],
      friday_end: ~T[17:00:00],
      saturday_enabled: false,
      saturday_start: nil,
      saturday_end: nil,
      sunday_enabled: false,
      sunday_start: nil,
      sunday_end: nil
    }
  end

  @doc """
  Returns demo calendar integrations (empty for demos).
  """
  @spec get_demo_calendar_integrations(integer()) :: []
  def get_demo_calendar_integrations(_user_id) do
    # Demo users don't have real calendar integrations
    []
  end

  @doc """
  Returns demo availability breaks (empty for demos).
  """
  @spec get_demo_availability_breaks(integer()) :: []
  def get_demo_availability_breaks(_profile_id) do
    # Demo users don't have breaks configured
    []
  end

  @doc """
  Returns demo availability overrides (empty for demos).
  """
  @spec get_demo_availability_overrides(integer()) :: []
  def get_demo_availability_overrides(_profile_id) do
    # Demo users don't have overrides configured
    []
  end
end
