defmodule Tymeslot.AnnouncementsTestCatalog do
  @moduledoc false
  # Test-only fixture catalog. Tests swap `:announcement_catalogs` to
  # `[__MODULE__]` so they can assert against deterministic content
  # rather than coupling to whatever entries Core ships with at the time.

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
        cta_path: nil,
        published_at: ~U[2026-01-01 00:00:00Z]
      },
      %Announcement{
        key: "test_beta",
        title: "Beta",
        body: "Second test announcement",
        image_path: "/images/announcements/test_beta.svg",
        cta_label: "Try Beta",
        cta_path: "/dashboard/beta",
        published_at: ~U[2026-02-01 00:00:00Z]
      }
    ]
  end
end
