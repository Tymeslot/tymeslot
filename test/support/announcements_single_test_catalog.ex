defmodule Tymeslot.AnnouncementsSingleTestCatalog do
  @moduledoc false
  # Test-only fixture catalog with a single announcement. Tests that need to
  # assert single-item carousel behaviour (no step indicator, "Got it" label)
  # swap `:announcement_catalogs` to `[__MODULE__]`.

  alias Tymeslot.Announcements.Announcement

  @spec list() :: [Announcement.t()]
  def list do
    [
      %Announcement{
        key: "test_solo",
        title: "Solo",
        body: "Single test announcement",
        image_path: nil,
        cta_label: nil,
        cta_path: nil,
        published_at: ~U[2026-01-01 00:00:00Z]
      }
    ]
  end
end
