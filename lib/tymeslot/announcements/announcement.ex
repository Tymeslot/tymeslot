defmodule Tymeslot.Announcements.Announcement do
  @moduledoc """
  In-memory representation of a single feature announcement.

  Authored in `Tymeslot.Announcements.Catalog` (and optionally a SaaS-side
  catalog registered via the `:announcement_catalogs` config).
  """

  @type t :: %__MODULE__{
          key: String.t(),
          title: String.t(),
          body: String.t(),
          image_path: String.t() | nil,
          cta_label: String.t() | nil,
          cta_path: String.t() | nil,
          published_at: DateTime.t()
        }

  @enforce_keys [:key, :title, :body, :published_at]
  defstruct key: nil,
            title: nil,
            body: nil,
            image_path: nil,
            cta_label: nil,
            cta_path: nil,
            published_at: nil
end
