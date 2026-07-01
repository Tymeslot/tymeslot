defmodule Tymeslot.Onboarding do
  @moduledoc """
  Context module for onboarding business logic.
  """

  alias Tymeslot.Auth.UserQueries
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
      case mark_onboarding_complete(user) do
        {:ok, _updated_user} = result ->
          :telemetry.execute([:tymeslot, :onboarding, :completed], %{count: 1}, %{})
          result

        error ->
          error
      end
    end
  end

  @doc """
  Marks a user's onboarding as complete.
  """
  @spec mark_onboarding_complete(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def mark_onboarding_complete(user) do
    UserQueries.mark_onboarding_complete(user)
  end

  @doc """
  Checks if a user has completed onboarding.
  """
  @spec onboarding_completed?(Ecto.Schema.t()) :: boolean()
  def onboarding_completed?(%{onboarding_completed_at: nil}), do: false
  def onboarding_completed?(_user), do: true

  @doc """
  Marks the post-onboarding dashboard tour as seen. Idempotent.
  """
  @spec mark_dashboard_tour_seen(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def mark_dashboard_tour_seen(user) do
    if dashboard_tour_seen?(user) do
      {:ok, user}
    else
      UserQueries.mark_dashboard_tour_seen(user)
    end
  end

  @doc """
  Returns true if the user has already seen the post-onboarding dashboard tour.
  """
  @spec dashboard_tour_seen?(Ecto.Schema.t()) :: boolean()
  def dashboard_tour_seen?(%{dashboard_tour_seen_at: nil}), do: false
  def dashboard_tour_seen?(_user), do: true

  @doc """
  Whether the host has manually ticked the given dashboard setup item off. The
  set of valid keys is owned by the widget, not this context — callers validate
  the key at the boundary before persisting.
  """
  @spec dashboard_setup_item_done?(Ecto.Schema.t(), String.t()) :: boolean()
  def dashboard_setup_item_done?(user, key) when is_binary(key),
    do: key in (user.dashboard_setup_done_items || [])

  @doc """
  Toggles a dashboard setup item's manually-done state and persists the result.
  """
  @spec toggle_dashboard_setup_item(Ecto.Schema.t(), String.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_dashboard_setup_item(user, key) when is_binary(key) do
    items = user.dashboard_setup_done_items || []
    next = if key in items, do: List.delete(items, key), else: [key | items]
    UserQueries.set_dashboard_setup_done_items(user, next)
  end

  @doc """
  Permanently closes the dashboard onboarding widget for the host. Idempotent.
  """
  @spec dismiss_dashboard_setup(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def dismiss_dashboard_setup(user) do
    if dashboard_setup_dismissed?(user) do
      {:ok, user}
    else
      UserQueries.mark_dashboard_setup_dismissed(user)
    end
  end

  @doc """
  Returns true once the host has closed the dashboard onboarding widget.
  """
  @spec dashboard_setup_dismissed?(Ecto.Schema.t()) :: boolean()
  def dashboard_setup_dismissed?(%{dashboard_setup_dismissed_at: nil}), do: false
  def dashboard_setup_dismissed?(_user), do: true

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
