defmodule Tymeslot.Onboarding do
  @moduledoc """
  Context module for onboarding business logic.
  """

  alias Tymeslot.Auth
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  @doc """
  Creates a mock profile for development mode.
  """
  @spec create_dev_profile() :: map()
  def create_dev_profile do
    %{
      id: 1,
      user_id: 1,
      username: nil,
      full_name: nil,
      timezone: Profiles.get_default_timezone(),
      buffer_minutes: 15,
      advance_booking_days: 90,
      min_advance_hours: 3,
      avatar: nil,
      booking_theme: "1"
    }
  end

  @doc """
  Creates a mock user for development mode.
  """
  @spec create_dev_user() :: map()
  def create_dev_user do
    %{
      id: 1,
      email: "dev@example.com",
      name: "Development User",
      onboarding_completed_at: nil
    }
  end

  @doc """
  Gets or creates a profile for the given user, handling both dev and production modes.
  """
  @spec get_or_create_profile(integer(), boolean()) ::
          {:ok, Ecto.Schema.t() | map()} | {:error, any()}
  def get_or_create_profile(user_id, dev_mode \\ false) do
    if dev_mode do
      {:ok, create_dev_profile()}
    else
      Profiles.get_or_create_profile(user_id)
    end
  end

  @doc """
  Completes the onboarding process for a user.
  """
  @spec complete_onboarding(Ecto.Schema.t() | map(), boolean()) ::
          {:ok, Ecto.Schema.t() | map()} | {:error, any()}
  def complete_onboarding(user, dev_mode \\ false) do
    if dev_mode do
      {:ok, user}
    else
      case Auth.mark_onboarding_complete(user) do
        {:ok, _updated_user} = result ->
          :telemetry.execute([:tymeslot, :onboarding, :completed], %{count: 1}, %{})
          result

        error ->
          error
      end
    end
  end

  @doc """
  Seeds each booking theme with a video background so the onboarding preview —
  and the published page — shows motion out of the box.

  Picks one random preset for the user and applies it to every theme in
  `theme_ids` that does not already use a video background. Idempotent: a theme
  that already has a video background (a returning user, or one who picked their
  own) is left untouched, so the choice is never overwritten or re-randomised.
  """
  @spec ensure_preview_video_backgrounds(map(), [String.t()]) :: :ok
  def ensure_preview_video_backgrounds(%{id: profile_id}, theme_ids)
      when is_integer(profile_id) and is_list(theme_ids) do
    preset = ThemeCustomizations.random_video_preset()
    Enum.each(theme_ids, &put_video_background_unless_set(profile_id, &1, preset))
  end

  def ensure_preview_video_backgrounds(_profile, _theme_ids), do: :ok

  defp put_video_background_unless_set(profile_id, theme_id, preset) do
    case ThemeCustomizations.get_by_profile_and_theme(profile_id, theme_id) do
      %{background_type: "video"} ->
        :ok

      _other ->
        ThemeCustomizations.upsert_theme_customization(profile_id, theme_id, %{
          "background_type" => "video",
          "background_value" => preset
        })
    end
  end
end
