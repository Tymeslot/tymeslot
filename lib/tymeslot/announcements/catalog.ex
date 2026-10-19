defmodule Tymeslot.Announcements.Catalog do
  @moduledoc """
  Core's canonical source of feature announcements. Add a new entry every time
  a noteworthy user-facing feature ships.

  User-facing content (`title`, `body`, `bullets`, `cta_label`) is translated
  through the `onboarding` gettext domain — the same domain that owns the modal
  chrome. Because `list/0` resolves these `dgettext/2` calls when it runs, and it
  runs on connected dashboard mount with the request locale already set, each
  user sees announcements in their own language. Every new string added here
  must be translated into all supported locales or the gettext completeness test
  fails.

  The `:key` MUST be globally unique and never change after release — it is the
  identity used in `user_seen_announcements`, and unlike the copy it is not a
  translatable string.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Announcements.Announcement

  @time_off_published_at ~U[2026-09-19 00:00:00Z]
  @time_off_expires_at ~U[2026-10-19 00:00:00Z]

  @video_providers_published_at ~U[2026-09-22 00:00:00Z]
  @video_providers_expires_at ~U[2026-10-22 00:00:00Z]

  @meeting_locations_published_at ~U[2026-09-23 00:00:00Z]
  @meeting_locations_expires_at ~U[2026-10-23 00:00:00Z]

  @group_bookings_published_at ~U[2026-10-07 00:00:00Z]
  @group_bookings_expires_at ~U[2026-11-06 00:00:00Z]

  @spec list() :: [Announcement.t()]
  def list do
    # One builder per announcement keeps this ordered list trivial and each
    # entry's translatable copy readable in isolation.
    [
      group_bookings(),
      meeting_locations(),
      video_providers(),
      time_off()
    ]
  end

  defp group_bookings do
    %Announcement{
      key: "group_bookings",
      title: dgettext("onboarding", "Host webinars, workshops and classes"),
      body:
        dgettext(
          "onboarding",
          "Turn any meeting type into a group session. Set how many people can join and " <>
            "each slot stays open until it's full, so one booking page can run your webinar, " <>
            "workshop, class or office hours. Everyone books themselves in, gets their own " <>
            "confirmation and calendar invite, and can cancel or reschedule without asking you."
        ),
      image_path: "/images/announcements/group-bookings.svg",
      published_at: @group_bookings_published_at,
      expires_at: @group_bookings_expires_at
    }
  end

  defp meeting_locations do
    %Announcement{
      key: "meeting_locations",
      title: dgettext("onboarding", "Let people choose where you meet"),
      body:
        dgettext(
          "onboarding",
          "A meeting type can now offer several places to meet: in person at an address, " <>
            "a video call or a phone call. The person booking picks the one that suits " <>
            "them, and can change it when they reschedule. Offer more than one video " <>
            "service and they choose which one the meeting runs on."
        ),
      image_path: "/images/announcements/meeting-locations.svg",
      cta_label: dgettext("onboarding", "Read the docs"),
      cta_docs_slug: "meeting-locations",
      published_at: @meeting_locations_published_at,
      expires_at: @meeting_locations_expires_at
    }
  end

  defp video_providers do
    %Announcement{
      key: "video_providers_2026_09",
      title: dgettext("onboarding", "Meet on Jitsi, kMeet or Nextcloud Talk"),
      body:
        dgettext(
          "onboarding",
          "Three more video providers join Zoom, Google Meet, Teams and MiroTalk in the " <>
            "integrations picker. Point Tymeslot at your own Jitsi or Nextcloud and every " <>
            "booking gets a room of its own: a Talk conversation keeps its lobby shut until " <>
            "the meeting starts, moves when you reschedule and is deleted when you cancel. " <>
            "kMeet needs no setup at all."
        ),
      image_path: "/images/announcements/video-providers.svg",
      cta_label: dgettext("onboarding", "Read the docs"),
      cta_docs_slug: "nextcloud-talk",
      published_at: @video_providers_published_at,
      expires_at: @video_providers_expires_at
    }
  end

  defp time_off do
    %Announcement{
      key: "time_off",
      title: dgettext("onboarding", "Close the days you are away"),
      body:
        dgettext(
          "onboarding",
          "Add a holiday on the availability page and those days stop being offered, across " <>
            "every schedule and every meeting type, without a blocking event in any calendar " <>
            "you have connected. Give the first and last day a time when you leave mid-" <>
            "afternoon or come back mid-morning. Bookings already in your diary keep their " <>
            "times, and you are shown which ones before you save. Nobody booking you sees why " <>
            "the days are closed."
        ),
      image_path: "/images/announcements/time-off.svg",
      published_at: @time_off_published_at,
      expires_at: @time_off_expires_at
    }
  end
end
