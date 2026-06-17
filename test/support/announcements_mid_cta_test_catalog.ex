defmodule Tymeslot.AnnouncementsMidCtaTestCatalog do
  @moduledoc false
  # Test-only fixture catalog with three announcements.
  # `test_gamma` sits in the middle of the list (published_at between alpha and
  # beta) and carries a CTA — exercising the `has_cta? and not on_last?` render
  # branch that shows a secondary CTA button alongside Next.
  # The outer two items are deliberately CTA-free or CTA-only-last so existing
  # test assertions remain valid when this catalog is used in isolation.

  alias Tymeslot.Announcements.Announcement

  @spec list() :: [Announcement.t()]
  def list do
    [
      %Announcement{
        key: "test_alpha",
        title: "Alpha",
        body: "First test announcement",
        image_path: nil,
        cta_label: nil,
        cta_docs_slug: nil,
        published_at: ~U[2026-01-01 00:00:00Z]
      },
      %Announcement{
        key: "test_gamma",
        title: "Gamma",
        body: "Middle test announcement with a CTA",
        image_path: nil,
        cta_label: "Try Gamma",
        cta_docs_slug: "gamma",
        published_at: ~U[2026-01-15 00:00:00Z]
      },
      %Announcement{
        key: "test_beta",
        title: "Beta",
        body: "Second test announcement",
        image_path: "/images/announcements/test_beta.svg",
        cta_label: "Try Beta",
        cta_docs_slug: "beta",
        published_at: ~U[2026-02-01 00:00:00Z]
      }
    ]
  end
end
