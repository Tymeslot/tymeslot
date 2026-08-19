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

  @published_at ~U[2026-06-05 00:00:00Z]
  @expires_at ~U[2026-07-05 00:00:00Z]

  @private_links_published_at ~U[2026-06-16 00:00:00Z]
  @private_links_expires_at ~U[2026-07-16 00:00:00Z]

  @guests_published_at ~U[2026-06-19 00:00:00Z]
  @guests_expires_at ~U[2026-07-19 00:00:00Z]

  @hub_published_at ~U[2026-07-06 00:00:00Z]
  @hub_expires_at ~U[2026-08-05 00:00:00Z]

  @event_colours_published_at ~U[2026-07-06 00:00:00Z]
  @event_colours_expires_at ~U[2026-08-05 00:00:00Z]

  @languages_published_at ~U[2026-08-10 00:00:00Z]
  @languages_expires_at ~U[2026-09-09 00:00:00Z]

  @booking_limits_published_at ~U[2026-08-07 00:00:00Z]
  @booking_limits_expires_at ~U[2026-09-06 00:00:00Z]

  @availability_schedules_published_at ~U[2026-08-14 00:00:00Z]
  @availability_schedules_expires_at ~U[2026-09-13 00:00:00Z]

  @booking_approval_published_at ~U[2026-08-19 00:00:00Z]
  @booking_approval_expires_at ~U[2026-09-18 00:00:00Z]

  @spec list() :: [Announcement.t()]
  def list do
    # One builder per announcement keeps this ordered list trivial and each
    # entry's translatable copy readable in isolation. The catch-all slide stays
    # last — add smaller improvements to its bullets rather than spawning new
    # entries.
    [
      booking_approval(),
      availability_schedules(),
      booking_limits(),
      app_languages(),
      integrations_hub(),
      calendar_event_colours(),
      guest_attendees_rsvp(),
      private_booking_links(),
      custom_booking_questions(),
      meeting_payments(),
      zoom_integration(),
      more_features()
    ]
  end

  defp booking_approval do
    %Announcement{
      key: "booking_approval",
      title: dgettext("onboarding", "Approve bookings before they're confirmed"),
      body:
        dgettext(
          "onboarding",
          "Turn on approval for a meeting type and its bookings wait for you. The slot is " <>
            "held so nobody else can take it, the person booking is told it's a request " <>
            "rather than a confirmed meeting, and your answer is one click from the email. " <>
            "Don't answer in time and the request lapses on its own."
        ),
      image_path: "/images/announcements/booking-approval.svg",
      cta_label: dgettext("onboarding", "Read the docs"),
      cta_docs_slug: "booking-approval",
      published_at: @booking_approval_published_at,
      expires_at: @booking_approval_expires_at
    }
  end

  defp availability_schedules do
    %Announcement{
      key: "availability_schedules",
      title: dgettext("onboarding", "Give every meeting type its own hours"),
      body:
        dgettext(
          "onboarding",
          "Availability is now built from named schedules - office hours, evening consults, " <>
            "weekend intensives - and every meeting type follows the one you choose. Keep up " <>
            "to five, each with its own hours, breaks and booking rules; anything you don't " <>
            "assign follows your default schedule."
        ),
      image_path: "/images/announcements/availability-schedules.svg",
      cta_label: dgettext("onboarding", "Read the docs"),
      cta_docs_slug: "availability-schedules",
      published_at: @availability_schedules_published_at,
      expires_at: @availability_schedules_expires_at
    }
  end

  defp booking_limits do
    %Announcement{
      key: "booking_limits",
      title: dgettext("onboarding", "Cap how many bookings you take"),
      body:
        dgettext(
          "onboarding",
          "Set a maximum number of bookings per day, week or month - for a single meeting " <>
            "type, or across your whole account. Once a day reaches its cap it disappears " <>
            "from your booking page, so nobody can book you past the limit you set."
        ),
      image_path: "/images/announcements/booking-limits.svg",
      published_at: @booking_limits_published_at,
      expires_at: @booking_limits_expires_at
    }
  end

  defp app_languages do
    %Announcement{
      key: "app_languages",
      title: dgettext("onboarding", "Tymeslot now speaks your language"),
      body:
        dgettext(
          "onboarding",
          "The whole app - your dashboard, booking pages and every email - is now available " <>
            "in German, French, Italian, Ukrainian and Czech. Tymeslot follows your browser's " <>
            "language automatically, or pick one yourself in Account settings. Your invitees " <>
            "get booking pages and confirmations in their own language, too."
        ),
      image_path: "/images/announcements/languages.svg",
      published_at: @languages_published_at,
      expires_at: @languages_expires_at
    }
  end

  defp integrations_hub do
    %Announcement{
      key: "integrations_hub",
      title: dgettext("onboarding", "All your integrations in one place"),
      body:
        dgettext(
          "onboarding",
          "Calendars, video and payments now live together in one Integrations hub. See at " <>
            "a glance what's connected and what needs attention, reconnect a provider in a " <>
            "click, and add something new - all from a single screen instead of hunting " <>
            "through separate settings pages."
        ),
      image_path: "/images/announcements/integrations-hub.svg",
      published_at: @hub_published_at,
      expires_at: @hub_expires_at
    }
  end

  defp calendar_event_colours do
    %Announcement{
      key: "calendar_event_colours",
      title: dgettext("onboarding", "Colour-code your calendar events"),
      body:
        dgettext(
          "onboarding",
          "Give any event its own colour, right from your dashboard agenda. Colours you set " <>
            "in Tymeslot write back to your connected calendar, and colours already on your " <>
            "Google or CalDAV events show up here too - so your day is colour-coded exactly " <>
            "the way you like it, everywhere you look."
        ),
      image_path: "/images/announcements/event-colours.svg",
      published_at: @event_colours_published_at,
      expires_at: @event_colours_expires_at
    }
  end

  defp guest_attendees_rsvp do
    %Announcement{
      key: "guest_attendees_rsvp",
      title: dgettext("onboarding", "Invite guests to any booking"),
      body:
        dgettext(
          "onboarding",
          "Bookings can now include additional guests. Each guest gets their own email " <>
            "invitation and can RSVP with a tap, so everyone who needs to be there is on the " <>
            "invite - without anyone booking a second time. Set a guest limit per meeting " <>
            "type to keep group sizes in check."
        ),
      image_path: "/images/announcements/guest-rsvp.svg",
      published_at: @guests_published_at,
      expires_at: @guests_expires_at
    }
  end

  defp private_booking_links do
    %Announcement{
      key: "private_booking_links",
      title: dgettext("onboarding", "Share private booking links"),
      body:
        dgettext(
          "onboarding",
          "Every meeting type now has its own direct link that takes people straight to " <>
            "booking it - without showing your other meeting types. Mark a type as unlisted " <>
            "to keep it off your public page, and randomise its link any time to make it " <>
            "unguessable or to retire an old one."
        ),
      image_path: "/images/announcements/private-booking-links.svg",
      published_at: @private_links_published_at,
      expires_at: @private_links_expires_at
    }
  end

  defp custom_booking_questions do
    %Announcement{
      key: "custom_booking_questions",
      title: dgettext("onboarding", "Ask the right questions up front"),
      body:
        dgettext(
          "onboarding",
          "Add custom questions to any meeting type - short text, long answers, " <>
            "dropdowns and more - so you have exactly what you need before each booking."
        ),
      image_path: "/images/announcements/custom-questions.svg",
      cta_label: dgettext("onboarding", "Read the docs"),
      cta_docs_slug: "custom-questions",
      published_at: @published_at,
      expires_at: @expires_at
    }
  end

  defp meeting_payments do
    %Announcement{
      key: "meeting_payments",
      title: dgettext("onboarding", "Get paid when people book"),
      body:
        dgettext(
          "onboarding",
          "Collect payment automatically at the moment of booking, with " <>
            "Stripe-powered checkout built right into your booking page."
        ),
      image_path: "/images/announcements/payments.svg",
      cta_label: dgettext("onboarding", "Read the docs"),
      cta_docs_slug: "payments",
      published_at: @published_at,
      expires_at: @expires_at
    }
  end

  defp zoom_integration do
    %Announcement{
      key: "zoom_integration",
      title: dgettext("onboarding", "Meet on Zoom, automatically"),
      body:
        dgettext(
          "onboarding",
          "Connect your Zoom account and Tymeslot creates a Zoom meeting for every " <>
            "booking - the link is added to the calendar invite and confirmation automatically."
        ),
      image_path: "/images/announcements/zoom.svg",
      cta_label: dgettext("onboarding", "Read the docs"),
      cta_docs_slug: "zoom",
      published_at: @published_at,
      expires_at: @expires_at
    }
  end

  # Catch-all slide so smaller improvements are surfaced without a modal each.
  defp more_features do
    %Announcement{
      key: "more_features_2026_06",
      title: dgettext("onboarding", "Plus a host of improvements"),
      body: dgettext("onboarding", "A few more things we've shipped lately:"),
      bullets: [
        dgettext("onboarding", "Slack notifications when a booking is made"),
        dgettext("onboarding", "Faster, more responsive Quill and Rhythm booking pages"),
        dgettext(
          "onboarding",
          "Booking pages and emails now in German, French, Ukrainian and Italian"
        ),
        dgettext(
          "onboarding",
          "Smarter embeds that auto-fit their height, with an optional column layout"
        )
      ],
      published_at: @published_at,
      expires_at: @expires_at
    }
  end
end
