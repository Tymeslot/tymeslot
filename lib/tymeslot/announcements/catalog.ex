defmodule Tymeslot.Announcements.Catalog do
  @moduledoc """
  Core's canonical, English-only source of feature announcements. Add a new
  entry every time a noteworthy user-facing feature ships.

  Announcement content is intentionally not translated — all entries stay in
  English. The `:key` MUST be globally unique and never change after release
  — it is the identity used in `user_seen_announcements`.
  """

  alias Tymeslot.Announcements.Announcement

  @published_at ~U[2026-06-05 00:00:00Z]
  @expires_at ~U[2026-07-05 00:00:00Z]

  @private_links_published_at ~U[2026-06-16 00:00:00Z]
  @private_links_expires_at ~U[2026-07-16 00:00:00Z]

  @spec list() :: [Announcement.t()]
  def list do
    [
      %Announcement{
        key: "private_booking_links",
        title: "Share private booking links",
        body:
          "Every meeting type now has its own direct link that takes people straight to " <>
            "booking it — without showing your other meeting types. Mark a type as unlisted " <>
            "to keep it off your public page, and randomise its link any time to make it " <>
            "unguessable or to retire an old one.",
        published_at: @private_links_published_at,
        expires_at: @private_links_expires_at
      },
      %Announcement{
        key: "custom_booking_questions",
        title: "Ask the right questions up front",
        body:
          "Add custom questions to any meeting type — short text, long answers, " <>
            "dropdowns and more — so you have exactly what you need before each booking.",
        image_path: "/images/announcements/custom-questions.svg",
        cta_label: "Read the docs",
        cta_docs_slug: "custom-questions",
        published_at: @published_at,
        expires_at: @expires_at
      },
      %Announcement{
        key: "meeting_payments",
        title: "Get paid when people book",
        body:
          "Collect payment automatically at the moment of booking, with " <>
            "Stripe-powered checkout built right into your booking page.",
        image_path: "/images/announcements/payments.svg",
        cta_label: "Read the docs",
        cta_docs_slug: "payments",
        published_at: @published_at,
        expires_at: @expires_at
      },
      %Announcement{
        key: "zoom_integration",
        title: "Meet on Zoom, automatically",
        body:
          "Connect your Zoom account and Tymeslot creates a Zoom meeting for every " <>
            "booking — the link is added to the calendar invite and confirmation automatically.",
        image_path: "/images/announcements/zoom.svg",
        cta_label: "Read the docs",
        cta_docs_slug: "zoom",
        published_at: @published_at,
        expires_at: @expires_at
      },
      # Catch-all slide so smaller improvements are surfaced without a modal each.
      # Keep this last in the list and add to it rather than spawning new entries.
      %Announcement{
        key: "more_features_2026_06",
        title: "Plus a host of improvements",
        body: "A few more things we've shipped lately:",
        bullets: [
          "Slack notifications when a booking is made",
          "Faster, more responsive Quill and Rhythm booking pages",
          "Booking pages and emails now in German, French, Ukrainian and Italian",
          "Smarter embeds that auto-fit their height, with an optional column layout"
        ],
        published_at: @published_at,
        expires_at: @expires_at
      }
    ]
  end
end
