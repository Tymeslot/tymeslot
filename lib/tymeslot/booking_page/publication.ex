defmodule Tymeslot.BookingPage.Publication do
  @moduledoc """
  Coordinates the "booking page is live" business rule, which spans two domains:
  Profiles (the host's username) and MeetingTypes (their bookable types).

  A host's booking page is considered *published* the first time they have both
  a username set and at least one active meeting type. This module is the single
  place that evaluates that rule and stamps `booking_page_published_at` — every
  path that can make a page live (manual or default meeting-type creation, or
  setting a username) funnels through `maybe_publish/1` so the transition can
  never be silently missed.

  The actual write is the idempotent, race-safe stamp in
  `Profiles.mark_booking_page_published/1`; this module only adds the
  meeting-type half of the condition and emits the once-per-host telemetry on
  the publish transition.
  """

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

  @doc """
  Stamps the host's booking page as published if it has just become live, and
  emits the `[:tymeslot, :booking_page, :published]` telemetry once on the
  transition. Safe to call from any path that might make a page live; it is a
  no-op when the live condition is not yet met or the page is already published.
  """
  @spec maybe_publish(integer()) :: :ok
  def maybe_publish(user_id) when is_integer(user_id) do
    with {:ok, profile} <- Profiles.get_or_create_profile(user_id),
         nil <- profile.booking_page_published_at,
         true <- MeetingTypes.has_active_meeting_types?(user_id),
         {:ok, :published} <- Profiles.mark_booking_page_published(profile) do
      :telemetry.execute([:tymeslot, :booking_page, :published], %{count: 1}, %{
        theme: profile.booking_theme
      })
    else
      _other -> :ok
    end
  end
end
