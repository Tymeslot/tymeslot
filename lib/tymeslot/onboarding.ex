defmodule Tymeslot.Onboarding do
  @moduledoc """
  Context module for onboarding business logic.
  """

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Onboarding.OnboardingQueries
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  require Logger

  @manual_dashboard_setup_items ~w(avatar intro embed)

  # How a host can keep their booking link on the last setup step, any one of
  # which finishes onboarding.
  @keep_methods ~w(first_person share_sheet email_me copy signature phone)

  @doc """
  Gets or creates a profile for the given user.
  """
  @spec get_or_create_profile(integer()) :: {:ok, Ecto.Schema.t()} | {:error, any()}
  def get_or_create_profile(user_id), do: Profiles.get_or_create_profile(user_id)

  @doc """
  Emails the host their own booking link, with a signature line and a QR code.

  Enqueues one job per user per ten minutes; a second call inside the window
  returns `:ok` without a second email.
  """
  @spec email_booking_link(Ecto.Schema.t() | map()) :: :ok | {:error, term()}
  def email_booking_link(%{id: user_id}) do
    case EmailScheduler.schedule_booking_link(user_id) do
      {:ok, _outcome} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "The ways a host can keep their booking link (`keep_booking_link/3`)."
  @spec keep_methods() :: [String.t()]
  def keep_methods, do: @keep_methods

  @doc """
  Records that the host kept their booking link on the last setup step, by
  `method` (one of `keep_methods/0`), which completes their onboarding.

  `email_me` emails the link first (`email_booking_link/1`) and counts only
  once the email is queued. Then the profile's first share is stamped, the
  generated username settled, onboarding completed and
  `[:tymeslot, :onboarding, :link_kept]` emitted with the method. Every step
  is idempotent, so keeping the link again is harmless.
  """
  @spec keep_booking_link(Ecto.Schema.t(), Ecto.Schema.t(), String.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, :unknown_method | {:email, term()} | term()}
  def keep_booking_link(user, profile, method) when method in @keep_methods do
    with :ok <- maybe_email_link(user, method),
         {:ok, _outcome} <- Profiles.mark_booking_link_shared(profile),
         {:ok, _profile} <- Profiles.ensure_default_username(profile),
         {:ok, completed} <- complete_onboarding(user) do
      # The only analytics path for kept links; Core never client-pushes it.
      :telemetry.execute([:tymeslot, :onboarding, :link_kept], %{}, %{
        user_id: user.id,
        method: method
      })

      {:ok, completed}
    end
  end

  def keep_booking_link(_user, _profile, _method), do: {:error, :unknown_method}

  defp maybe_email_link(user, "email_me") do
    case email_booking_link(user) do
      :ok -> :ok
      {:error, reason} -> {:error, {:email, reason}}
    end
  end

  defp maybe_email_link(_user, _method), do: :ok

  @doc """
  Subscribes the calling process to the onboarding events of `user_id`.

  The one event today is `{:onboarding, :preview_opened}`: the host opened
  their own booking page from the handoff link on the last setup step (the
  QR code), on another device (`broadcast_preview_opened/1`).
  """
  @spec subscribe(pos_integer()) :: :ok | {:error, term()}
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(Tymeslot.PubSub, topic(user_id))

  @doc """
  Tells the host's onboarding sessions that their booking page was opened
  from the handoff link. A failed broadcast is logged and swallowed: nothing
  the booking page does depends on it.
  """
  @spec broadcast_preview_opened(pos_integer()) :: :ok
  def broadcast_preview_opened(user_id) do
    case Phoenix.PubSub.broadcast(Tymeslot.PubSub, topic(user_id), {:onboarding, :preview_opened}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to broadcast onboarding preview_opened",
          user_id: user_id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  defp topic(user_id), do: "onboarding:#{user_id}"

  @doc """
  Completes the onboarding process for a user.
  """
  @spec complete_onboarding(Ecto.Schema.t() | map()) ::
          {:ok, Ecto.Schema.t() | map()} | {:error, any()}
  def complete_onboarding(user) do
    case mark_onboarding_complete(user) do
      {:ok, _updated_user} = result ->
        :telemetry.execute([:tymeslot, :onboarding, :completed], %{count: 1}, %{})
        result

      error ->
        error
    end
  end

  @doc """
  Marks a user's onboarding as complete. A user who has already completed it
  keeps the original completion time.
  """
  @spec mark_onboarding_complete(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, :not_found}
  def mark_onboarding_complete(user) do
    OnboardingQueries.mark_onboarding_complete(user)
  end

  @doc """
  Checks if a user has completed onboarding.
  """
  @spec onboarding_completed?(Ecto.Schema.t()) :: boolean()
  def onboarding_completed?(%{onboarding_completed_at: nil}), do: false
  def onboarding_completed?(_user), do: true

  # How long after completing onboarding the live step still counts as the
  # host's own unfinished session: the life of the preview token that step
  # shows. A reconnect (the mail app took the screen) comes back within
  # minutes.
  @rejoin_window_seconds 3600

  @doc """
  Whether the user completed onboarding within the last hour, so a
  reconnect to the live step is still the session that completed it rather
  than a visit to a settled account.
  """
  @spec recently_completed?(Ecto.Schema.t() | map(), DateTime.t()) :: boolean()
  def recently_completed?(user, now \\ DateTime.utc_now())

  def recently_completed?(%{onboarding_completed_at: %DateTime{} = at}, now),
    do: DateTime.diff(now, at) <= @rejoin_window_seconds

  def recently_completed?(_user, _now), do: false

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
  The dashboard setup items a host ticks off by hand, to skip them. The
  provider items (calendar, video) are deliberately absent: they complete only
  from a real connection.

  A key stored by an earlier version of the checklist may linger in
  `dashboard_setup_done_items`; nothing reads it, and it can no longer be
  toggled.
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
  Candidate rows for an onboarding scan: one map per account whose signup or
  verification falls after `window_start` (accounts pending deletion left
  out), carrying `user_id`, `signup_at`, `verified_at`, `timezone` and
  `page_published?`.

  Options:

    * `:compose` - a function given the row query, with `users` as its first
      binding and a map select, that returns it extended (for example with a
      `select_merge/3` of extra per-user facts). Defaults to the identity.
  """
  @spec list_candidates_since(DateTime.t(), keyword()) :: [map()]
  def list_candidates_since(window_start, opts \\ []),
    do: OnboardingQueries.list_candidates_since(window_start, compose(opts))

  @doc """
  The same candidate row as `list_candidates_since/2` for one account,
  whatever its signup date, or `nil` when there is no such account. Takes the
  same options.
  """
  @spec get_candidate(integer(), keyword()) :: map() | nil
  def get_candidate(user_id, opts \\ []),
    do: OnboardingQueries.get_candidate(user_id, compose(opts))

  defp compose(opts), do: Keyword.get(opts, :compose, &Function.identity/1)

  @doc """
  Seeds each booking theme with a video background so the onboarding preview —
  and the published page — shows motion out of the box.

  Picks a random preset for each theme in `theme_ids` from the videos that
  theme offers, sharing one preset between themes that offer it, and applies
  it where no video background is set yet (an uploaded image stays stored,
  as with any background choice). Themes without video are skipped.
  Idempotent: a theme that already has a video background (a returning
  user, or one who picked their own) is left untouched, so the choice is
  never overwritten or re-randomised.
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

  # Decided on the row the save has locked, so a background the organiser
  # sets meanwhile (an upload in another tab) is never replaced. A theme's
  # default does not count as set: only what the row stores does.
  defp put_video_background_unless_set(profile_id, theme_id, preset) do
    ThemeCustomizations.upsert_theme_customization(profile_id, theme_id, fn stored, _defaults ->
      if stored["background_type"] == "video",
        do: %{},
        else: %{"background_type" => "video", "background_value" => preset}
    end)
  end
end
