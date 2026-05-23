defmodule Tymeslot.Integrations.MeetingProvisioning do
  @moduledoc """
  Cross-context orchestration: given a `(calendar_integration_id, video_integration_id,
  user_id, event_details)` tuple, decides whether to ask the calendar provider to
  provision the video link inline (via `conferenceData.createRequest`) or to provision
  it separately and stitch the URL into the event description afterwards.

  ## Strategies

  * `:none` — no video integration requested.
  * `{:inline, video_id}` — Google Calendar and Google Meet share the same Google
    account. Attaching `conferenceData.createRequest` to the calendar create/update
    call lets Google provision the Meet link in a single round-trip and avoids
    creating a duplicate calendar event.
  * `{:separate, video_id}` — any other combination. The video provider is called
    independently and the resulting URL is written into the event description.

  The `:inline` path for *edits* requires the calendar update call to include
  `conferenceData` and `conferenceDataVersion=1`. That wiring is not yet
  implemented in `EventOperations`; the edit flow therefore falls back to
  `:separate` (see `EditWorkflow.sync_video_integration_async/3`).
  """

  require Logger

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Google.ConferenceData
  alias Tymeslot.Integrations.Video

  @type plan ::
          {:inline, video_id :: integer()}
          | {:separate, video_id :: integer()}
          | :none

  @doc """
  Returns the provisioning plan for the given combination of integrations.

  Detects the Google same-account case via a private overlap check.
  All other combinations yield `:separate` or `:none`.
  """
  @spec plan(integer() | nil, integer() | nil, integer()) :: plan()
  def plan(calendar_integration_id, video_integration_id, user_id)

  def plan(_cal_id, nil, _user_id), do: :none

  def plan(cal_id, vid_id, user_id)
      when is_integer(cal_id) and is_integer(vid_id) and is_integer(user_id) do
    if google_account_overlap?(cal_id, vid_id, user_id) do
      {:inline, vid_id}
    else
      {:separate, vid_id}
    end
  end

  def plan(_cal_id, _vid_id, _user_id), do: :none

  @doc """
  Attaches the `conference_data` key to `event_data` when the plan is `:inline`.

  For any other plan the map is returned unchanged. This is the only place that
  builds the `conferenceData.createRequest` payload — no caller needs to know
  what it looks like.
  """
  @spec attach_conference_data(map(), plan()) :: map()
  def attach_conference_data(event_data, {:inline, _video_id}) do
    Map.put(event_data, :conference_data, ConferenceData.create_request())
  end

  def attach_conference_data(event_data, _plan), do: event_data

  @doc """
  Finalises the video context after the calendar create call completes.

  For the `:inline` plan: extracts the Meet URL from the created-event
  response and builds the `video_context` map.

  Returns `{:ok, video_context}` on success. Returns
  `{:error, :no_meet_url, video_context}` when Google did not return a Meet URL
  (e.g. a pending `createRequest` or missing `entryPoints`). The error tuple
  still includes `video_integration_id` so callers can persist the integration
  association even without a URL.

  For `:separate` and `:none`: returns `{:ok, video_context}` unchanged.
  """
  @spec finalise(map(), map(), plan()) ::
          {:ok, map()} | {:error, :no_meet_url, map()}
  def finalise(video_context, created, {:inline, video_id}) do
    case ConferenceData.meet_url_from_event(created) do
      nil ->
        Logger.warning(
          "Google Calendar create succeeded but did not return a Meet URL; " <>
            "the event has no video link",
          video_integration_id: video_id
        )

        {:error, :no_meet_url, Map.put(video_context, :video_integration_id, video_id)}

      url when is_binary(url) ->
        {:ok,
         Map.merge(video_context, %{
           meeting_url: url,
           room_id: Video.extract_room_id(url),
           video_integration_id: video_id
         })}
    end
  end

  def finalise(video_context, _created, _plan), do: {:ok, video_context}

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Returns true when the given calendar and video integrations both belong to
  # the same Google account (Google Calendar + Google Meet, sharing
  # provider_account_id). Returns false for any missing/mismatched case.
  defp google_account_overlap?(calendar_integration_id, video_integration_id, user_id) do
    with {:ok, cal} <- Calendar.get_integration(calendar_integration_id, user_id),
         {:ok, vid} <- Video.fetch_integration_for_user(video_integration_id, user_id),
         true <- cal.provider == "google" and vid.provider == "google_meet",
         account_id when is_binary(account_id) and account_id != "" <- cal.provider_account_id,
         true <- vid.provider_account_id == account_id do
      true
    else
      _other -> false
    end
  end
end
