defmodule Tymeslot.FreeBusy do
  @moduledoc """
  Publishes a profile's busy intervals as an iCalendar `VFREEBUSY` feed.

  The feed is exposed at `GET /free-busy/:token`. A profile opts in by
  generating a secret token (`enable_feed/1`); clearing it (`disable_feed/1`)
  takes the feed offline. Busy intervals are derived from the same connected
  calendar events the availability engine treats as blocking, so the published
  free/busy reflects exactly what blocks bookings.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.FreebusyGenerator
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema

  @token_bytes 24
  @default_horizon_days 60

  @doc "Returns the profile owning `token`, or `{:error, :not_found}`."
  @spec get_profile_by_token(String.t()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_profile_by_token(token), do: ProfileQueries.get_by_freebusy_token(token)

  @doc "Whether the profile has an active free/busy feed."
  @spec feed_enabled?(ProfileSchema.t()) :: boolean()
  def feed_enabled?(%ProfileSchema{freebusy_token: token}),
    do: is_binary(token) and token != ""

  @doc """
  Ensures the profile has a feed token, generating one if absent. Idempotent —
  an already-enabled feed keeps its existing token.
  """
  @spec enable_feed(ProfileSchema.t()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def enable_feed(%ProfileSchema{} = profile) do
    if feed_enabled?(profile) do
      {:ok, profile}
    else
      ProfileQueries.update_freebusy_token(profile, generate_token())
    end
  end

  @doc "Issues a fresh token, invalidating any previously shared feed URL."
  @spec regenerate_token(ProfileSchema.t()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def regenerate_token(%ProfileSchema{} = profile),
    do: ProfileQueries.update_freebusy_token(profile, generate_token())

  @doc "Disables the feed by clearing the token."
  @spec disable_feed(ProfileSchema.t()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def disable_feed(%ProfileSchema{} = profile),
    do: ProfileQueries.update_freebusy_token(profile, nil)

  @doc """
  Renders the `VFREEBUSY` document for the profile over a rolling window
  (`now` → `now + horizon_days`, default #{@default_horizon_days}).
  """
  @spec feed(ProfileSchema.t(), keyword()) :: String.t()
  def feed(%ProfileSchema{} = profile, opts \\ []) do
    horizon_days = Keyword.get(opts, :horizon_days, @default_horizon_days)
    window_start = DateTime.truncate(Keyword.get(opts, :now, DateTime.utc_now()), :second)
    window_end = DateTime.add(window_start, horizon_days, :day)

    FreebusyGenerator.generate(
      uid: "freebusy-#{profile.id}@tymeslot.com",
      window_start: window_start,
      window_end: window_end,
      organizer_email: organizer_email(profile),
      intervals: busy_intervals(profile, window_start, window_end)
    )
  end

  @doc """
  Returns the profile's busy intervals (UTC `{start, end}` pairs) overlapping
  the window, derived from connected-calendar events that block availability.
  """
  @spec busy_intervals(ProfileSchema.t(), DateTime.t(), DateTime.t()) ::
          [FreebusyGenerator.interval()]
  def busy_intervals(%ProfileSchema{user_id: user_id}, window_start, window_end) do
    integration_ids =
      user_id
      |> CalendarIntegrationQueries.list_active_for_user()
      |> Enum.map(& &1.id)

    integration_ids
    |> CalendarEventQueries.in_range({window_start, window_end})
    |> Enum.filter(&CalendarEvent.blocking?/1)
    |> Enum.flat_map(&event_interval/1)
  end

  # Timed events map directly; all-day events span midnight-to-midnight UTC.
  defp event_interval(%CalendarEvent{
         all_day: false,
         start_at: %DateTime{} = s,
         end_at: %DateTime{} = e
       }),
       do: [{s, e}]

  defp event_interval(%CalendarEvent{
         all_day: true,
         start_date: %Date{} = sd,
         end_date: %Date{} = ed
       }) do
    [{DateTime.new!(sd, ~T[00:00:00], "Etc/UTC"), DateTime.new!(ed, ~T[00:00:00], "Etc/UTC")}]
  end

  defp event_interval(_other), do: []

  defp organizer_email(%ProfileSchema{user: %{email: email}})
       when is_binary(email) and email != "",
       do: email

  defp organizer_email(_profile), do: nil

  defp generate_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
