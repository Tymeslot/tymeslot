defmodule Tymeslot.Onboarding do
  @moduledoc """
  Context module for onboarding business logic.
  """

  alias Tymeslot.Onboarding.OnboardingQueries
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog

  @manual_dashboard_setup_items ~w(theme meeting_types share)

  @spec create_dev_profile() :: map()
  defp create_dev_profile do
    %{
      id: 1,
      user_id: 1,
      username: nil,
      full_name: nil,
      timezone: Profiles.get_default_timezone(),
      avatar: nil,
      booking_theme: Catalog.default_id()
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
    OnboardingQueries.mark_onboarding_complete(user)
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
      OnboardingQueries.mark_dashboard_tour_seen(user)
    end
  end

  @doc """
  Returns true if the user has already seen the post-onboarding dashboard tour.
  """
  @spec dashboard_tour_seen?(Ecto.Schema.t()) :: boolean()
  def dashboard_tour_seen?(%{dashboard_tour_seen_at: nil}), do: false
  def dashboard_tour_seen?(_user), do: true

  @doc """
  The dashboard setup items a host ticks off by hand. The provider items
  (calendar, video) are deliberately absent: they complete only from a real
  connection.
  """
  @spec manual_dashboard_setup_items() :: [String.t()]
  def manual_dashboard_setup_items, do: @manual_dashboard_setup_items

  @doc """
  Toggles a hand-tickable dashboard setup item and returns the user with the
  stored list.

  The flip is decided by what is stored rather than by the given struct, so a
  tick made from another tab is never overwritten by a stale copy. Any key
  outside `manual_dashboard_setup_items/0` is refused.
  """
  @spec toggle_dashboard_setup_item(Ecto.Schema.t(), term()) ::
          {:ok, Ecto.Schema.t()} | {:error, :unknown_item | :not_found}
  def toggle_dashboard_setup_item(user, key) when key in @manual_dashboard_setup_items,
    do: OnboardingQueries.toggle_dashboard_setup_done_item(user, key)

  def toggle_dashboard_setup_item(_user, _key), do: {:error, :unknown_item}

  @doc """
  Permanently closes the dashboard onboarding widget for the host. Idempotent.
  """
  @spec dismiss_dashboard_setup(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def dismiss_dashboard_setup(user) do
    if dashboard_setup_dismissed?(user) do
      {:ok, user}
    else
      OnboardingQueries.mark_dashboard_setup_dismissed(user)
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

  Picks a random preset for each theme in `theme_ids` from the videos that
  theme offers, sharing one preset between themes that offer it, and applies
  it where no video background is set yet (as a choice of the theme's
  background option, so an uploaded image it replaces is removed with its
  file). Themes without video are skipped. Idempotent: a theme that already
  has a video background (a returning user, or one who picked their own) is
  left untouched, so the choice is never overwritten or re-randomised.
  """
  @spec ensure_preview_video_backgrounds(map(), [String.t()]) :: :ok
  def ensure_preview_video_backgrounds(%{id: profile_id}, theme_ids)
      when is_integer(profile_id) and is_list(theme_ids) do
    theme_ids
    |> Map.new(&{&1, ThemeCustomizations.video_preset_keys(&1)})
    |> ThemeCustomizations.preview_videos()
    |> Enum.each(fn {theme_id, preset} ->
      put_video_background_unless_set(profile_id, theme_id, preset)
    end)
  end

  def ensure_preview_video_backgrounds(_profile, _theme_ids), do: :ok

  # A choice of the background group, as the dashboard makes it: the save
  # drops any upload the video replaces, and the update deletes its file.
  defp put_video_background_unless_set(profile_id, theme_id, preset) do
    case ThemeCustomizations.get_by_profile_and_theme(profile_id, theme_id) do
      %{settings: %{"background_type" => "video"}} ->
        :ok

      _other ->
        ThemeCustomizations.apply_option(profile_id, theme_id, :background, %{
          "field" => "video",
          "value" => preset
        })
    end
  end
end
